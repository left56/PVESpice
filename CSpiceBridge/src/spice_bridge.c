/**
 * spice_bridge.c - C bridge between Swift and libspice-client-glib
 *
 * This module wraps GObject-based spice-client-glib APIs into plain C
 * functions callable from Swift. It manages:
 * - SpiceSession and channel lifecycle
 * - Display surface callbacks (create, invalidate, destroy)
 * - Input forwarding (keyboard, mouse)
 * - A GLib main loop on a dedicated thread
 */

#include "spice_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <os/log.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>
#include <netdb.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <TargetConditionals.h>

#define BLOG(fmt, ...) do { \
    os_log(OS_LOG_DEFAULT, "[SpiceBridge] " fmt, ##__VA_ARGS__); \
} while(0)

#ifdef HAVE_SPICE
#include <spice-client.h>
#include <spice/vd_agent.h>
#include <gio/gio.h>
#include <libsoup/soup.h>
/* Phodav / libsoup：WebDAV 与 VD_AGENT_CLIPBOARD_FILE_LIST（与 spice-gtk-session 一致）。 */
#include <libphodav/phodav.h>

/* spice-session.c 导出；供虚拟根 Phodav 与 WebDAV 通道使用。 */
PhodavServer *spice_session_get_webdav_server(SpiceSession *session);
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#include <CoreVideo/CoreVideo.h>
/* VideoToolbox per-channel callback registry (compiled into libspice-client-glib) */
extern void vtb_register_video_callback(SpiceChannel *ch,
    void (*cb)(CVImageBufferRef, void *), void *ctx);
extern void vtb_unregister_video_callback(SpiceChannel *ch);
#endif /* __APPLE__ */
#endif /* HAVE_SPICE */

// ---------------------------------------------------------------------------
// Singleton shared GLib main loop — one thread runs g_main_loop_run on the
// global default context for the app lifetime.  All SpiceSessions attach
// their GIO sources to that context, so every session's callbacks are
// dispatched by this single thread (no multi-thread context ownership fights).
// ---------------------------------------------------------------------------
#ifdef HAVE_SPICE
static GMainLoop      *s_shared_loop = NULL;
static pthread_once_t  s_loop_once   = PTHREAD_ONCE_INIT;

static void *shared_loop_thread(void *arg) {
    (void)arg;
    pthread_setname_np("com.pvespice.glib-mainloop");
    BLOG("shared GLib loop: started");
    g_main_loop_run(s_shared_loop);
    BLOG("shared GLib loop: exited");
    return NULL;
}

static void init_shared_loop(void) {
    s_shared_loop = g_main_loop_new(NULL, FALSE); // global default context
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&t, &attr, shared_loop_thread, NULL);
    pthread_attr_destroy(&attr);
}

static void ensure_shared_loop(void) {
    pthread_once(&s_loop_once, init_shared_loop);
}
#endif // HAVE_SPICE
// ---------------------------------------------------------------------------

struct SpiceBridgeSession {
    SpiceBridgeCallbacks callbacks;
    SpiceBridgeState state;

#ifdef HAVE_SPICE
    SpiceSession *spice_session;
    SpiceMainChannel *main_channel;
    SpiceInputsChannel *inputs_channel;
    SpiceDisplayChannel *display_channel;
    SpicePlaybackChannel *playback_channel;
    SpiceRecordChannel   *record_channel;
    // Disconnect synchronization: quit_loop waits until on_session_disconnected fires
    GMutex   disconnect_mutex;
    GCond    disconnect_cond;
    gboolean disconnect_notified;

    gboolean host_clipboard_announced; /* client announced grab (by-demand); guest may request */
    guint    clipboard_epoch;          /* bumped on disconnect to drop async clipboard work */

    SpiceWebdavChannel *webdav_channel; /* weak: owned by SpiceSession */
    gchar *clipboard_phodav_tmpdir;     /* mkdtemp under G_TMP_DIR */
    GHashTable *clipboard_shared_files; /* GFile* -> owned gchar* path under /.spice-clipboard */
    guint8 *host_clipboard_file_list;   /* VD_AGENT_CLIPBOARD_FILE_LIST blob for guest REQUEST */
    gsize   host_clipboard_file_list_len;
#endif

    int32_t display_width;
    int32_t display_height;
    pthread_mutex_t lock;

    // TLS relay — bypasses GIO's missing TLS backend (GDummyTlsBackend)
    int relay_listen_fd;   // local loopback listener (-1 = unused)
    int relay_running;     // 1 while relay workers are active

    // macOS Catalyst: socketpair + open-fd relay (no bind/listen needed)
    int  relay_main_fd;        // fds[0] for main channel; -1 = not in use
    int  relay_use_open_fd;    // 1 = use socketpair for non-main channels
    char relay_host[256];
    int  relay_tls_port;
    char relay_proxy_host[256];
    int  relay_proxy_port;
    int  relay_has_proxy;
    char relay_tls_sni_host[256];
};

// Route a debug message to the Swift debug callback
static void debug_notify(SpiceBridgeSession *session, const char *fmt, ...) {
    if (!session || !session->callbacks.on_debug) return;
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    session->callbacks.on_debug(session->callbacks.context, buf);
}
#define DBLOG(session, fmt, ...) do { \
    BLOG(fmt, ##__VA_ARGS__); \
    debug_notify(session, fmt, ##__VA_ARGS__); \
} while(0)

// Helper to notify state changes
static void notify_state_change(SpiceBridgeSession *session, SpiceBridgeState new_state) {
    pthread_mutex_lock(&session->lock);
    session->state = new_state;
    pthread_mutex_unlock(&session->lock);

    if (session->callbacks.on_state_changed) {
        session->callbacks.on_state_changed(session->callbacks.context, new_state);
    }
}

#ifdef HAVE_SPICE

#ifdef __APPLE__
static void dispatch_video_frame(CVImageBufferRef pixbuf, void *ctx)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)ctx;
    if (session->callbacks.on_video_frame)
        session->callbacks.on_video_frame(session->callbacks.context, (void *)pixbuf);
}
#endif /* __APPLE__ */

// Forward declarations
static void on_channel_open_fd(SpiceChannel *channel, int with_tls, gpointer user_data);
static void on_channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer user_data);
static void on_display_primary_create(SpiceDisplayChannel *channel, gint format, gint width, gint height, gint stride, gint shmid, gpointer imgdata, gpointer user_data);
static void on_display_invalidate(SpiceDisplayChannel *channel, gint x, gint y, gint w, gint h, gpointer user_data);
static void on_display_primary_destroy(SpiceDisplayChannel *channel, gpointer user_data);
static void on_cursor_set(SpiceCursorChannel *channel, gint width, gint height, gint hot_x, gint hot_y, gpointer rgba, gpointer user_data);
static void on_cursor_move(SpiceCursorChannel *channel, gint x, gint y, gpointer user_data);
static void on_playback_start(SpicePlaybackChannel *channel, gint format, gint channels, gint freq, gpointer user_data);
static void on_playback_data(SpicePlaybackChannel *channel, gpointer data, gint size, gpointer user_data);
static void on_playback_stop(SpicePlaybackChannel *channel, gpointer user_data);
static void on_record_start(SpiceRecordChannel *channel, gint format, gint channels, gint freq, gpointer user_data);
static void on_record_stop(SpiceRecordChannel *channel, gpointer user_data);

static gboolean on_clipboard_selection_grab(SpiceMainChannel *main, guint selection,
                                            guint32 *types, guint32 ntypes, gpointer user_data);
static void on_clipboard_selection(SpiceMainChannel *main, guint selection, guint type,
                                   const guchar *data, guint size, gpointer user_data);
static gboolean on_clipboard_selection_request(SpiceMainChannel *main, guint selection,
                                               guint type, gpointer user_data);
static void on_clipboard_selection_release(SpiceMainChannel *main, guint selection, gpointer user_data);
static void on_main_agent_update(SpiceChannel *channel, gpointer user_data);
static void on_webdav_port_opened(GObject *obj, GParamSpec *pspec, gpointer user_data);
static void on_new_file_transfer(SpiceMainChannel *main, SpiceFileTransferTask *task, gpointer user_data);
static void on_file_transfer_task_finished(SpiceFileTransferTask *task, GError *error, gpointer user_data);

static void clipboard_file_bridge_cleanup_pre_session_unref(SpiceBridgeSession *session);
static void clipboard_file_bridge_delete_tmpdir(SpiceBridgeSession *session);
static gboolean clipboard_webdav_port_open(SpiceBridgeSession *session);
static GFile *bridge_g_file_new_for_uri_or_path(const char *s);
static gchar *clipboard_webdav_share_file(PhodavVirtualDir *root, GFile *source,
                                           const gchar *session_tmpdir);
static void clipboard_mac_paste_ensure_exists(PhodavVirtualDir *root);
static gchar *strv_concat_paths(gchar **strv, gsize *size_out);
static gboolean set_clipboard_files_invoke(gpointer user_data);

// GObject signal handlers

static void on_channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    const char *evname = "UNKNOWN";
    switch (event) {
        case SPICE_CHANNEL_OPENED:           evname = "OPENED"; break;
        case SPICE_CHANNEL_CLOSED:           evname = "CLOSED"; break;
        case SPICE_CHANNEL_ERROR_CONNECT:    evname = "ERR_CONNECT"; break;
        case SPICE_CHANNEL_ERROR_TLS:        evname = "ERR_TLS"; break;
        case SPICE_CHANNEL_ERROR_LINK:       evname = "ERR_LINK"; break;
        case SPICE_CHANNEL_ERROR_AUTH:       evname = "ERR_AUTH"; break;
        case SPICE_CHANNEL_ERROR_IO:         evname = "ERR_IO"; break;
        default: break;
    }
    DBLOG(session, "ch_event %s %s",
          g_type_name(G_TYPE_FROM_INSTANCE(channel)), evname);
}

static void on_channel_new(SpiceSession *s, SpiceChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    gint channel_id = 0;
    g_object_get(channel, "channel-id", &channel_id, NULL);
    DBLOG(session, "ch_new type=%s id=%d",
          g_type_name(G_TYPE_FROM_INSTANCE(channel)), channel_id);

    // Always watch channel events so we see connect/error on every channel
    g_signal_connect(channel, "channel-event", G_CALLBACK(on_channel_event), session);

    // macOS: non-main channels get a socketpair+relay via the open-fd signal
    if (session->relay_use_open_fd && !SPICE_IS_MAIN_CHANNEL(channel)) {
        g_signal_connect(channel, "open-fd", G_CALLBACK(on_channel_open_fd), session);
    }

    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        DBLOG(session, "ch_new: main channel, connecting");
        session->main_channel = SPICE_MAIN_CHANNEL(channel);
        session->host_clipboard_announced = FALSE;
        g_signal_connect(channel, "main-clipboard-selection-grab",
                         G_CALLBACK(on_clipboard_selection_grab), session);
        g_signal_connect(channel, "main-clipboard-selection",
                         G_CALLBACK(on_clipboard_selection), session);
        g_signal_connect(channel, "main-clipboard-selection-request",
                         G_CALLBACK(on_clipboard_selection_request), session);
        g_signal_connect(channel, "main-clipboard-selection-release",
                         G_CALLBACK(on_clipboard_selection_release), session);
        g_signal_connect(channel, "main-agent-update",
                         G_CALLBACK(on_main_agent_update), session);
        g_signal_connect(channel, "new-file-transfer",
                         G_CALLBACK(on_new_file_transfer), session);
        spice_channel_connect(channel);
    } else if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        DBLOG(session, "ch_new: display channel, connecting");
        session->display_channel = SPICE_DISPLAY_CHANNEL(channel);

        g_signal_connect(channel, "display-primary-create",
                        G_CALLBACK(on_display_primary_create), session);
        g_signal_connect(channel, "display-invalidate",
                        G_CALLBACK(on_display_invalidate), session);
        g_signal_connect(channel, "display-primary-destroy",
                        G_CALLBACK(on_display_primary_destroy), session);

        /* Request H.264 as the preferred video codec for display streams.
         * VideoToolbox provides hardware H.264 decode on iOS.
         * Falls back to MJPEG automatically if the server doesn't support H.264. */
        spice_channel_connect(channel);
        static const gint codecs[] = {
            SPICE_VIDEO_CODEC_TYPE_H264,
            SPICE_VIDEO_CODEC_TYPE_H265,
            SPICE_VIDEO_CODEC_TYPE_MJPEG,
        };
        GError *codec_err = NULL;
        spice_display_channel_change_preferred_video_codec_types(
            channel, codecs, G_N_ELEMENTS(codecs), &codec_err);
        if (codec_err) {
            DBLOG(session, "ch_new: codec pref not accepted: %s", codec_err->message);
            g_error_free(codec_err);
        } else {
            DBLOG(session, "ch_new: preferred codecs: H264, H265, MJPEG");
        }
#ifdef __APPLE__
        vtb_register_video_callback(channel, dispatch_video_frame, session);
#endif
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        BLOG("on_channel_new: is inputs channel, connecting");
        session->inputs_channel = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
    } else if (SPICE_IS_CURSOR_CHANNEL(channel)) {
        BLOG("on_channel_new: is cursor channel, connecting");
        g_signal_connect(channel, "cursor-set",
                        G_CALLBACK(on_cursor_set), session);
        g_signal_connect(channel, "cursor-move",
                        G_CALLBACK(on_cursor_move), session);
        spice_channel_connect(channel);
    } else if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {
        DBLOG(session, "ch_new: playback channel, connecting");
        session->playback_channel = SPICE_PLAYBACK_CHANNEL(channel);
        g_signal_connect(channel, "playback-start", G_CALLBACK(on_playback_start), session);
        g_signal_connect(channel, "playback-data",  G_CALLBACK(on_playback_data),  session);
        g_signal_connect(channel, "playback-stop",  G_CALLBACK(on_playback_stop),  session);
        spice_channel_connect(channel);
    } else if (SPICE_IS_RECORD_CHANNEL(channel)) {
        DBLOG(session, "ch_new: record channel, connecting");
        session->record_channel = SPICE_RECORD_CHANNEL(channel);
        g_signal_connect(channel, "record-start", G_CALLBACK(on_record_start), session);
        g_signal_connect(channel, "record-stop",  G_CALLBACK(on_record_stop),  session);
        spice_channel_connect(channel);
    } else if (SPICE_IS_WEBDAV_CHANNEL(channel)) {
        DBLOG(session, "ch_new: webdav channel, connecting");
        session->webdav_channel = SPICE_WEBDAV_CHANNEL(channel);
        g_signal_connect(channel, "notify::port-opened",
                         G_CALLBACK(on_webdav_port_opened), session);
        spice_channel_connect(channel);
    } else {
        spice_channel_connect(channel);
    }
}

static void on_channel_destroy(SpiceSession *s, SpiceChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        session->main_channel = NULL;
        session->host_clipboard_announced = FALSE;
    } else if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        session->display_channel = NULL;
#ifdef __APPLE__
        vtb_unregister_video_callback(channel);
#endif
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        session->inputs_channel = NULL;
    } else if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {
        session->playback_channel = NULL;
    } else if (SPICE_IS_RECORD_CHANNEL(channel)) {
        session->record_channel = NULL;
    } else if (SPICE_IS_WEBDAV_CHANNEL(channel)) {
        if (session->webdav_channel == SPICE_WEBDAV_CHANNEL(channel))
            session->webdav_channel = NULL;
    }
}

static void on_new_file_transfer(SpiceMainChannel *main, SpiceFileTransferTask *task, gpointer user_data)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    (void)main;
    if (!task || !session)
        return;
    g_signal_connect(task, "finished", G_CALLBACK(on_file_transfer_task_finished), session);
}

static void on_file_transfer_task_finished(SpiceFileTransferTask *task, GError *error, gpointer user_data)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    GFile *gf = NULL;
    gchar *path = NULL;

    if (!session || !session->callbacks.on_remote_file_transfer_saved)
        return;
    if (error) {
        DBLOG(session, "file xfer finished: %s", error->message);
        return;
    }
    g_object_get(task, "file", &gf, NULL);
    if (gf)
        path = g_file_get_path(gf);
    g_clear_object(&gf);
    if (path) {
        session->callbacks.on_remote_file_transfer_saved(session->callbacks.context, path);
        g_free(path);
    }
}

static void clipboard_file_bridge_cleanup_pre_session_unref(SpiceBridgeSession *session)
{
    if (!session)
        return;
    if (session->clipboard_shared_files) {
        g_hash_table_destroy(session->clipboard_shared_files);
        session->clipboard_shared_files = NULL;
    }
    g_free(session->host_clipboard_file_list);
    session->host_clipboard_file_list = NULL;
    session->host_clipboard_file_list_len = 0;
}

static gboolean bridge_delete_file_tree(GFile *dir, GError **err)
{
    GFileEnumerator *en;
    GFileInfo *info;
    gboolean ok = TRUE;

    en = g_file_enumerate_children(dir,
                                   G_FILE_ATTRIBUTE_STANDARD_NAME "," G_FILE_ATTRIBUTE_STANDARD_TYPE,
                                   G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, err);
    if (!en)
        return FALSE;
    while (ok && (info = g_file_enumerator_next_file(en, NULL, err))) {
        GFile *child = g_file_enumerator_get_child(en, info);
        if (g_file_info_get_file_type(info) == G_FILE_TYPE_DIRECTORY)
            ok = bridge_delete_file_tree(child, err);
        else
            ok = g_file_delete(child, NULL, err);
        g_object_unref(child);
        g_object_unref(info);
    }
    g_object_unref(en);
    if (!ok)
        return FALSE;
    return g_file_delete(dir, NULL, err);
}

static void clipboard_file_bridge_delete_tmpdir(SpiceBridgeSession *session)
{
    if (!session || !session->clipboard_phodav_tmpdir)
        return;
    {
        GFile *gf = g_file_new_for_path(session->clipboard_phodav_tmpdir);
        GError *err = NULL;
        if (!bridge_delete_file_tree(gf, &err)) {
            BLOG("clipboard: delete tmpdir failed: %s", err ? err->message : "?");
            g_clear_error(&err);
        }
        g_object_unref(gf);
    }
    g_free(session->clipboard_phodav_tmpdir);
    session->clipboard_phodav_tmpdir = NULL;
}

static gboolean bridge_file_equal_gconst(gconstpointer a, gconstpointer b)
{
    return g_file_equal((GFile *)a, (GFile *)b);
}

static gboolean clipboard_webdav_port_open(SpiceBridgeSession *session)
{
    gboolean open = FALSE;
    if (!session->webdav_channel)
        return FALSE;
    g_object_get(session->webdav_channel, "port-opened", &open, NULL);
    return open;
}

static GFile *bridge_g_file_new_for_uri_or_path(const char *s)
{
    if (!s || !s[0])
        return NULL;
    if (g_str_has_prefix(s, "file:"))
        return g_file_new_for_uri(s);
    return g_file_new_for_path(s);
}

/* 固定 WebDAV 路径：/.spice-clipboard/mac_paste/<basename>（来宾 Z: 下可预期） */
#define SPICE_WEBDAV_MAC_PASTE_DIR SPICE_WEBDAV_CLIPBOARD_FOLDER_PATH "/mac_paste"

static void clipboard_mac_paste_ensure_exists(PhodavVirtualDir *root)
{
    GError *err = NULL;
    PhodavVirtualDir *d;

    d = phodav_virtual_dir_new_dir(root, SPICE_WEBDAV_MAC_PASTE_DIR, &err);
    if (d)
        g_object_unref(d);
    if (err) {
        if (!g_error_matches(err, G_IO_ERROR, G_IO_ERROR_EXISTS))
            BLOG("phodav: mac_paste ensure: %s", err->message);
        g_clear_error(&err);
    }
}

/* 与 libphodav phodav-virtual-dir.c 中 struct _PhodavVirtualDir 布局一致（仅用于维护 children 链表）。
 * 若升级 phodav 后粘贴异常，请对照上游该结构体字段顺序。 */
typedef struct {
    GObject           parent_instance;
    gboolean          dummy;
    PhodavVirtualDir *parent;
    GList            *children;
    GFile            *real_root;
    gchar            *path;
} SpicePhodavVirtualDirLayout;

/* 从 mac_paste 虚拟目录移除已 attach 的真实文件（不触碰用户原始路径上的文件）。 */
static void clipboard_mac_paste_detach_real_children(PhodavVirtualDir *mac_dir)
{
    SpicePhodavVirtualDirLayout *vd = (SpicePhodavVirtualDirLayout *)mac_dir;
    gboolean again;

    do {
        GList *l;

        again = FALSE;
        for (l = vd->children; l; l = l->next) {
            GFile *child = G_FILE(l->data);

            if (PHODAV_IS_VIRTUAL_DIR(child))
                continue;
            vd->children = g_list_remove(vd->children, child);
            g_object_unref(child);
            again = TRUE;
            break;
        }
    } while (again);
}

#define CLIPBOARD_MAC_PASTE_STAGING_DIR "mac-paste-staging"

/* 删除会话 tmpdir 下 staging 目录（detach 之后调用，仅删我们创建的副本）。 */
static gboolean clipboard_mac_paste_staging_wipe(const gchar *session_tmpdir)
{
    gchar *p;
    GFile *gf;
    GError *err = NULL;
    gboolean ok;

    if (!session_tmpdir || !session_tmpdir[0])
        return TRUE;
    p = g_build_filename(session_tmpdir, CLIPBOARD_MAC_PASTE_STAGING_DIR, NULL);
    gf = g_file_new_for_path(p);
    g_free(p);
    if (!g_file_query_exists(gf, NULL)) {
        g_object_unref(gf);
        return TRUE;
    }
    ok = bridge_delete_file_tree(gf, &err);
    g_object_unref(gf);
    if (!ok) {
        BLOG("phodav: mac_paste staging wipe: %s", err ? err->message : "?");
        g_clear_error(&err);
    }
    return ok;
}

/* 在 staging 中选一个不冲突的目标名，将 source 复制到该处并 attach 到 mac_paste。 */
static gchar *clipboard_webdav_share_file(PhodavVirtualDir *root, GFile *source,
                                          const gchar *session_tmpdir)
{
    GFile *mac_gf = NULL;
    GFile *staging_root = NULL;
    GFile *dest = NULL;
    gchar *src_base = NULL;
    gchar *path = NULL;
    gchar *staging_path = NULL;
    GError *err = NULL;
    gint suffix;

    clipboard_mac_paste_ensure_exists(root);

    staging_path = g_build_filename(session_tmpdir, CLIPBOARD_MAC_PASTE_STAGING_DIR, NULL);
    staging_root = g_file_new_for_path(staging_path);
    g_free(staging_path);
    staging_path = NULL;

    if (!g_file_make_directory_with_parents(staging_root, NULL, &err)) {
        if (!g_error_matches(err, G_IO_ERROR, G_IO_ERROR_EXISTS)) {
            BLOG("phodav: staging mkdir: %s", err->message);
            g_clear_error(&err);
            goto out;
        }
        g_clear_error(&err);
    }

    src_base = g_file_get_basename(source);
    suffix = 1;
    dest = g_file_get_child(staging_root, src_base);
    while (g_file_query_exists(dest, NULL)) {
        gchar *nb = g_strdup_printf("%s_%d", src_base, suffix++);

        g_object_unref(dest);
        dest = g_file_get_child(staging_root, nb);
        g_free(nb);
    }

    if (!g_file_copy(source, dest,
                     G_FILE_COPY_OVERWRITE | G_FILE_COPY_TARGET_DEFAULT_PERMS,
                     NULL, NULL, NULL, &err)) {
        BLOG("phodav: staging copy: %s", err->message);
        g_clear_error(&err);
        goto out;
    }

    mac_gf = g_file_resolve_relative_path(G_FILE(root), ".spice-clipboard/mac_paste");
    if (!PHODAV_IS_VIRTUAL_DIR(mac_gf)) {
        BLOG("phodav: mac_paste path did not resolve to virtual dir");
        goto out;
    }

    if (!phodav_virtual_dir_attach_real_child(PHODAV_VIRTUAL_DIR(mac_gf), dest)) {
        BLOG("phodav: attach_real_child failed (duplicate name?)");
        goto out;
    }

    {
        gchar *attached_base = g_file_get_basename(dest);

        path = g_strdup_printf(SPICE_WEBDAV_MAC_PASTE_DIR "/%s", attached_base);
        g_free(attached_base);
    }

out:
    g_clear_object(&mac_gf);
    g_clear_object(&staging_root);
    g_clear_object(&dest);
    g_free(src_base);
    return path;
}

/* Same layout as spice-gtk strv_concat(): each strv[i] written with trailing NUL;
 * VD_AGENT_CLIPBOARD_FILE_LIST expects strv[0] == "copy" or "cut", then WebDAV paths. */
static gchar *strv_concat_paths(gchar **strv, gsize *size_out)
{
    gchar **str_p;
    gchar *arr;
    gchar *curr;

    g_return_val_if_fail(strv && size_out, NULL);
    *size_out = 0;
    for (str_p = strv; *str_p != NULL; str_p++)
        *size_out += strlen(*str_p) + 1;
    if (*size_out == 0)
        return NULL;
    arr = g_malloc(*size_out);
    for (str_p = strv, curr = arr; *str_p != NULL; str_p++)
        curr = g_stpcpy(curr, *str_p) + 1;
    return arr;
}

static void on_webdav_port_opened(GObject *obj, GParamSpec *pspec, gpointer user_data)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    gboolean open = FALSE;
    (void)pspec;
    g_object_get(obj, "port-opened", &open, NULL);
    if (open) {
        DBLOG(session, "webdav: port-opened (re-announce clipboard so FILE_LIST grab can succeed)");
        spice_bridge_clipboard_host_pasteboard_changed(session);
    }
}

typedef struct {
    SpiceBridgeSession *session;
    guint               epoch;
} HostClipboardIdle;

static gboolean host_clipboard_idle_fn(gpointer user_data)
{
    HostClipboardIdle *h = (HostClipboardIdle *)user_data;
    SpiceBridgeSession *session = h->session;

    if (h->epoch != session->clipboard_epoch) {
        DBLOG(session, "clipboard grab idle: skipped (epoch mismatch)");
        free(h);
        return G_SOURCE_REMOVE;
    }
    if (!session->main_channel) {
        DBLOG(session, "clipboard grab idle: skipped (no main channel)");
        free(h);
        return G_SOURCE_REMOVE;
    }
    if (!spice_main_channel_agent_test_capability(session->main_channel,
                                                   VD_AGENT_CAP_CLIPBOARD_BY_DEMAND)) {
        DBLOG(session, "clipboard grab idle: skipped (guest lacks VD_AGENT_CAP_CLIPBOARD_BY_DEMAND)");
        free(h);
        return G_SOURCE_REMOVE;
    }

    {
        guint32 types[2];
        guint ntypes = 1;

        types[0] = VD_AGENT_CLIPBOARD_UTF8_TEXT;
        if (session->host_clipboard_file_list_len > 0)
            types[ntypes++] = VD_AGENT_CLIPBOARD_FILE_LIST;

        DBLOG(session, "clipboard grab: ntypes=%u types0=0x%x types1=0x%x host_file_list_len=%zu",
              ntypes, (unsigned)types[0],
              ntypes > 1 ? (unsigned)types[1] : 0u,
              (size_t)session->host_clipboard_file_list_len);

        if (ntypes >= 2 && types[1] == VD_AGENT_CLIPBOARD_FILE_LIST)
            printf("[SpiceBridge] Grabbing clipboard with FILE_LIST enabled\n");

        spice_main_channel_clipboard_selection_grab(session->main_channel,
                                                    VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
                                                    types, (int)ntypes);
        session->host_clipboard_announced = TRUE;
    }

    free(h);
    return G_SOURCE_REMOVE;
}

typedef struct {
    SpiceBridgeSession *session;
    gchar **uris;
    gint count;
} SetClipboardFilesOp;

static void set_clipboard_files_op_free(SetClipboardFilesOp *op)
{
    if (!op)
        return;
    g_strfreev(op->uris);
    g_free(op);
}

static gboolean set_clipboard_files_invoke(gpointer user_data)
{
    SetClipboardFilesOp *op = user_data;
    SpiceBridgeSession *session = op->session;
    PhodavServer *phodav = NULL;
    PhodavVirtualDir *root = NULL;
    gchar **paths = NULL;
    gchar *blob = NULL;
    gsize blob_len = 0;
    gint i, n;
    GFile *file;
    gchar *path;
    gboolean ok = TRUE;

    if (!session->main_channel || !session->clipboard_shared_files) {
        DBLOG(session, "set_clipboard_files: main channel or clipboard state not ready");
        goto out;
    }

    if (!session->clipboard_phodav_tmpdir) {
        DBLOG(session, "set_clipboard_files: no Phodav share dir (init failed)");
        ok = FALSE;
        goto out;
    }

    if (op->count == 0) {
        g_hash_table_remove_all(session->clipboard_shared_files);
        g_free(session->host_clipboard_file_list);
        session->host_clipboard_file_list = NULL;
        session->host_clipboard_file_list_len = 0;
        goto announce;
    }

    if (!clipboard_webdav_port_open(session)) {
        DBLOG(session, "set_clipboard_files: WebDAV channel not open yet");
        ok = FALSE;
        goto out;
    }

    phodav = spice_session_get_webdav_server(session->spice_session);
    if (!phodav) {
        DBLOG(session, "set_clipboard_files: spice_session_get_webdav_server returned NULL");
        ok = FALSE;
        goto out;
    }

    g_object_get(phodav, "root-file", &root, NULL);
    if (!root || !PHODAV_IS_VIRTUAL_DIR(G_OBJECT(root))) {
        DBLOG(session, "set_clipboard_files: invalid Phodav root");
        ok = FALSE;
        g_clear_object(&root);
        goto out;
    }

    clipboard_mac_paste_ensure_exists(PHODAV_VIRTUAL_DIR(root));
    {
        GFile *mac_gf = g_file_resolve_relative_path(G_FILE(root), ".spice-clipboard/mac_paste");

        if (!PHODAV_IS_VIRTUAL_DIR(mac_gf)) {
            DBLOG(session, "set_clipboard_files: mac_paste did not resolve to PhodavVirtualDir");
            g_object_unref(mac_gf);
            ok = FALSE;
            g_clear_object(&root);
            goto out;
        }
        clipboard_mac_paste_detach_real_children(PHODAV_VIRTUAL_DIR(mac_gf));
        g_object_unref(mac_gf);
    }
    if (!clipboard_mac_paste_staging_wipe(session->clipboard_phodav_tmpdir)) {
        DBLOG(session, "set_clipboard_files: could not wipe mac_paste staging");
        ok = FALSE;
        g_clear_object(&root);
        goto out;
    }
    g_hash_table_remove_all(session->clipboard_shared_files);

    paths = g_new0(gchar *, (gsize)op->count + 2);
    paths[0] = (gchar *)"copy";
    n = 1;

    for (i = 0; i < op->count; i++) {
        file = bridge_g_file_new_for_uri_or_path(op->uris[i]);
        if (!file) {
            ok = FALSE;
            break;
        }
        path = (gchar *)g_hash_table_lookup(session->clipboard_shared_files, file);
        if (path) {
            paths[n++] = path;
            g_object_unref(file);
        } else {
            path = clipboard_webdav_share_file(PHODAV_VIRTUAL_DIR(root), file,
                                               session->clipboard_phodav_tmpdir);
            if (!path) {
                g_object_unref(file);
                ok = FALSE;
                break;
            }
            g_hash_table_insert(session->clipboard_shared_files, file, path);
            paths[n++] = path;
        }
    }

    g_clear_object(&root);

    if (!ok) {
        g_free(paths);
        goto out;
    }

    blob = strv_concat_paths(paths, &blob_len);
    g_free(paths);
    paths = NULL;

    if (!blob || blob_len == 0) {
        g_free(blob);
        ok = FALSE;
        goto out;
    }

    g_free(session->host_clipboard_file_list);
    session->host_clipboard_file_list = (guint8 *)blob;
    session->host_clipboard_file_list_len = blob_len;
    blob = NULL;

announce:
    {
        HostClipboardIdle *h = malloc(sizeof(HostClipboardIdle));
        if (h) {
            h->session = session;
            h->epoch = session->clipboard_epoch;
            g_main_context_invoke(NULL, host_clipboard_idle_fn, h);
        }
    }

out:
    g_clear_object(&root);
    g_free(paths);
    g_free(blob);
    if (!ok)
        DBLOG(session, "set_clipboard_files: failed");
    set_clipboard_files_op_free(op);
    return G_SOURCE_REMOVE;
}

static gboolean on_clipboard_selection_grab(SpiceMainChannel *main, guint selection,
                                            guint32 *types, guint32 ntypes, gpointer user_data)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    gboolean want_utf8 = FALSE;
    gboolean want_files = FALSE;
    guint i;

    (void)selection;
    session->host_clipboard_announced = FALSE;

    if (!types || ntypes == 0)
        return TRUE;

    for (i = 0; i < ntypes; i++) {
        if (types[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT)
            want_utf8 = TRUE;
        if (types[i] == VD_AGENT_CLIPBOARD_FILE_LIST)
            want_files = TRUE;
    }

    if (!want_utf8 && !want_files)
        return TRUE;

    if (!spice_main_channel_agent_test_capability(main, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND))
        return TRUE;

    if (want_utf8)
        spice_main_channel_clipboard_selection_request(main, selection, VD_AGENT_CLIPBOARD_UTF8_TEXT);
    if (want_files)
        spice_main_channel_clipboard_selection_request(main, selection, VD_AGENT_CLIPBOARD_FILE_LIST);
    return TRUE;
}

static void on_clipboard_selection(SpiceMainChannel *main, guint selection, guint type,
                                   const guchar *data, guint size, gpointer user_data)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    (void)main;
    (void)selection;

    if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
        if (!session->callbacks.on_remote_clipboard_utf8 || !data || size == 0)
            return;
        session->callbacks.on_remote_clipboard_utf8(session->callbacks.context, data, (size_t)size);
    } else if (type == VD_AGENT_CLIPBOARD_FILE_LIST) {
        SpiceBridgeRemoteClipboardFileListCallback cb = session->callbacks.on_remote_clipboard_file_list;
        if (!cb || !data || size == 0)
            return;
        cb(session->callbacks.context, data, (size_t)size);
    }
}

static gboolean on_clipboard_selection_request(SpiceMainChannel *main, guint selection,
                                               guint type, gpointer user_data)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    guint epoch_snap;

    if (!session->host_clipboard_announced)
        return FALSE;
    if (!spice_main_channel_agent_test_capability(main, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND))
        return FALSE;

    epoch_snap = session->clipboard_epoch;

    if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
        SpiceBridgeCopyHostClipboardUtf8Callback fetch = session->callbacks.copy_host_clipboard_utf8;
        char *text = NULL;
        size_t len = 0;

        if (!fetch)
            return FALSE;

#if defined(__APPLE__)
        __block char *cap_t = NULL;
        __block size_t cap_l = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (epoch_snap != session->clipboard_epoch)
                return;
            cap_t = fetch(session->callbacks.context, &cap_l);
        });
        text = cap_t;
        len = cap_l;
#else
        text = fetch(session->callbacks.context, &len);
#endif

        if (epoch_snap != session->clipboard_epoch) {
            free(text);
            return TRUE;
        }

        spice_main_channel_clipboard_selection_notify(main, selection,
                                                      VD_AGENT_CLIPBOARD_UTF8_TEXT,
                                                      (const guchar *)text,
                                                      text ? len : 0);
        free(text);
        return TRUE;
    }

    if (type == VD_AGENT_CLIPBOARD_FILE_LIST) {
        if (!session->host_clipboard_file_list || session->host_clipboard_file_list_len == 0)
            return FALSE;
        if (epoch_snap != session->clipboard_epoch)
            return TRUE;
        spice_main_channel_clipboard_selection_notify(main, selection,
                                                      VD_AGENT_CLIPBOARD_FILE_LIST,
                                                      session->host_clipboard_file_list,
                                                      session->host_clipboard_file_list_len);
        return TRUE;
    }

    return FALSE;
}

static void on_clipboard_selection_release(SpiceMainChannel *main, guint selection, gpointer user_data)
{
    /* Guest released *its* clipboard (VD_AGENT_CLIPBOARD_RELEASE → this signal).
     * spice-gtk clears guest-owned GtkClipboard state only — it does NOT drop
     * the client's spice_main_channel_clipboard_selection_grab announcement.
     * Clearing host_clipboard_announced here broke host→guest paste: REQUEST
     * was rejected with host_clipboard_announced == FALSE. */
    (void)main;
    (void)selection;
    (void)user_data;
}

static void on_main_agent_update(SpiceChannel *channel, gpointer user_data)
{
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    (void)channel;
    if (!session->main_channel)
        return;
    /* After caps / agent attach, BY_DEMAND becomes testable; re-offer host pasteboard
     * so a UIPasteboard notification that ran too early is not lost. */
    if (!spice_main_channel_agent_test_capability(session->main_channel,
                                                    VD_AGENT_CAP_CLIPBOARD_BY_DEMAND))
        return;
    spice_bridge_clipboard_host_pasteboard_changed(session);
}

static void on_session_disconnected(SpiceSession *spice_session, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "session: disconnected signal");
    // Unblock spice_bridge_quit_loop() which waits for this signal
    g_mutex_lock(&session->disconnect_mutex);
    session->disconnect_notified = TRUE;
    g_cond_signal(&session->disconnect_cond);
    g_mutex_unlock(&session->disconnect_mutex);
    notify_state_change(session, SPICE_BRIDGE_STATE_DISCONNECTED);
}

static void spice_glib_log_handler(const gchar *log_domain,
                                    GLogLevelFlags log_level,
                                    const gchar *message,
                                    gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    const char *level = (log_level & G_LOG_LEVEL_ERROR)    ? "ERR"  :
                        (log_level & G_LOG_LEVEL_CRITICAL) ? "CRIT" :
                        (log_level & G_LOG_LEVEL_WARNING)  ? "WARN" :
                        (log_level & G_LOG_LEVEL_MESSAGE)  ? "MSG"  : "DBG";
    DBLOG(session, "GLOG[%s/%s] %s",
          log_domain ? log_domain : "glib", level, message ? message : "");
}

static void on_display_primary_create(SpiceDisplayChannel *channel,
                                       gint format, gint width, gint height,
                                       gint stride, gint shmid, gpointer imgdata,
                                       gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    DBLOG(session, "display_create fmt=%d %dx%d stride=%d data=%p",
          format, width, height, stride, imgdata);

    pthread_mutex_lock(&session->lock);
    session->display_width = width;
    session->display_height = height;
    pthread_mutex_unlock(&session->lock);

    if (session->callbacks.on_display_create) {
        BLOG("on_display_primary_create: calling Swift on_display_create callback");
        SpiceBridgeSurface surface = {
            .surface_id = 0,
            .width = width,
            .height = height,
            .stride = stride,
            .format = (uint32_t)format,
            .data = (const uint8_t *)imgdata
        };
        session->callbacks.on_display_create(session->callbacks.context, &surface);
    }
}

static void on_display_invalidate(SpiceDisplayChannel *channel,
                                   gint x, gint y, gint w, gint h,
                                   gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (session->callbacks.on_display_invalidate) {
        SpiceBridgeRect rect = { .x = x, .y = y, .width = w, .height = h };

        // Get the current primary surface to obtain stride and data pointer
        SpiceDisplayPrimary primary;
        gint stride = 0;
        const uint8_t *data = NULL;
        if (spice_display_channel_get_primary(SPICE_CHANNEL(channel), 0, &primary)) {
            stride = primary.stride;
            data = (const uint8_t *)primary.data;
        }

        session->callbacks.on_display_invalidate(
            session->callbacks.context,
            0, // surface_id
            &rect,
            data,
            stride
        );
    }
}

static void on_display_primary_destroy(SpiceDisplayChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (session->callbacks.on_display_destroy) {
        session->callbacks.on_display_destroy(session->callbacks.context, 0);
    }
}

static void on_cursor_set(SpiceCursorChannel *channel,
                           gint width, gint height,
                           gint hot_x, gint hot_y,
                           gpointer rgba, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    if (session->callbacks.on_cursor_set) {
        session->callbacks.on_cursor_set(
            session->callbacks.context,
            width, height, hot_x, hot_y,
            (const uint8_t *)rgba
        );
    }
}

static void on_cursor_move(SpiceCursorChannel *channel,
                            gint x, gint y, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    if (session->callbacks.on_cursor_move) {
        session->callbacks.on_cursor_move(session->callbacks.context, x, y);
    }
}

static void on_playback_start(SpicePlaybackChannel *channel,
                               gint format, gint channels, gint freq,
                               gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "playback_start: fmt=%d ch=%d freq=%d", format, channels, freq);
    if (session->callbacks.on_playback_start)
        session->callbacks.on_playback_start(session->callbacks.context,
                                              (int32_t)channels, (int32_t)freq);
}

static void on_playback_data(SpicePlaybackChannel *channel,
                              gpointer data, gint size,
                              gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    if (session->callbacks.on_playback_data && data)
        session->callbacks.on_playback_data(session->callbacks.context,
                                             (const uint8_t *)data, (int32_t)size);
}

static void on_playback_stop(SpicePlaybackChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "playback_stop");
    if (session->callbacks.on_playback_stop)
        session->callbacks.on_playback_stop(session->callbacks.context);
}

static void on_record_start(SpiceRecordChannel *channel,
                             gint format, gint channels, gint freq,
                             gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "record_start: fmt=%d ch=%d freq=%d", format, channels, freq);
    if (session->callbacks.on_record_start)
        session->callbacks.on_record_start(session->callbacks.context,
                                            (int32_t)channels, (int32_t)freq);
}

static void on_record_stop(SpiceRecordChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "record_stop");
    if (session->callbacks.on_record_stop)
        session->callbacks.on_record_stop(session->callbacks.context);
}

#endif /* HAVE_SPICE */

// ---------------------------------------------------------------------------
// TLS relay — makes spice-glib see a plain SPICE server while we handle
// the proxy CONNECT + OpenSSL TLS handshake transparently.
//
// SPICE opens one TCP connection per channel (main, display, cursor, inputs).
// The relay listener accepts each connection and spawns a per-channel worker
// thread that does: proxy CONNECT → OpenSSL TLS → bidirectional relay.
// ---------------------------------------------------------------------------

typedef struct {
    SpiceBridgeSession *session;
    char real_host[256];
    int  real_tls_port;
    char proxy_host[64];
    int  proxy_port;
    int  has_proxy;
    int  client_fd;  // already-accepted fd (set per worker)
    /** Last CN=… from cert-subject / host-subject; used as TLS SNI (CONNECT 目标可为 pvespiceproxy:…)。 */
    char tls_sni_host[256];
} TlsRelayArgs;

/** 从 `OU=…,O=…,CN=hb.local` 取最后一个 `CN=` 的值作为 SNI。 */
static void fill_tls_sni_from_subject(const char *subject, char *out, size_t outlen)
{
    if (!out || outlen == 0) return;
    out[0] = '\0';
    if (!subject || !subject[0]) return;
    const char *scan = subject;
    const char *val = NULL;
    while ((scan = strstr(scan, "CN=")) != NULL) {
        val = scan + 3;
        scan = scan + 3;
    }
    if (!val || !*val) return;
    const char *e = val;
    while (*e && *e != ',' && *e != '/') e++;
    size_t n = (size_t)(e - val);
    if (n >= outlen) n = outlen - 1;
    memcpy(out, val, n);
    out[n] = '\0';
}

// Resolve hostname → IPv4
static int resolve_host(const char *host, struct in_addr *out) {
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) return -1;
    *out = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
    freeaddrinfo(res);
    return 0;
}

// Worker thread: handles one SPICE channel connection end-to-end
static void *tls_relay_worker(void *arg) {
    TlsRelayArgs *a = (TlsRelayArgs *)arg;
    SpiceBridgeSession *session = a->session;
    int client_fd = a->client_fd;
    int server_fd = -1;
    SSL_CTX *ctx  = NULL;
    SSL *ssl      = NULL;

    // 1. Connect to proxy or directly to server
    {
        const char *conn_host = a->has_proxy ? a->proxy_host : a->real_host;
        int  conn_port        = a->has_proxy ? a->proxy_port : a->real_tls_port;

        struct in_addr addr4;
        if (resolve_host(conn_host, &addr4) < 0) {
            DBLOG(session, "relay[%d]: resolve failed for %s", client_fd, conn_host);
            goto worker_cleanup;
        }
        struct sockaddr_in sa = {0};
        sa.sin_family = AF_INET;
        sa.sin_port   = htons((uint16_t)conn_port);
        sa.sin_addr   = addr4;

        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd >= 0) {
            int nodelay = 1;
            setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
        }
        if (server_fd < 0 || connect(server_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
            DBLOG(session, "relay[%d]: connect to %s:%d failed errno=%d",
                  client_fd, conn_host, conn_port, errno);
            goto worker_cleanup;
        }
    }

    // 2. HTTP CONNECT tunnel (if using proxy)
    if (a->has_proxy) {
        char req[512];
        snprintf(req, sizeof(req),
            "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n",
            a->real_host, a->real_tls_port,
            a->real_host, a->real_tls_port);
        send(server_fd, req, strlen(req), 0);

        char resp[1024] = {0};
        int total = 0;
        while (total < (int)sizeof(resp) - 1) {
            int r = (int)recv(server_fd, resp + total, sizeof(resp) - 1 - total, 0);
            if (r <= 0) break;
            total += r;
            if (strstr(resp, "\r\n\r\n")) break;
        }
        if (!strstr(resp, "200")) {
            DBLOG(session, "relay[%d]: proxy CONNECT failed: %.40s", client_fd, resp);
            goto worker_cleanup;
        }
    }

    // 3. TLS handshake
    {
        ctx = SSL_CTX_new(TLS_client_method());
        if (!ctx) { DBLOG(session, "relay[%d]: SSL_CTX_new failed", client_fd); goto worker_cleanup; }
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);

        ssl = SSL_new(ctx);
        if (!ssl) { DBLOG(session, "relay[%d]: SSL_new failed", client_fd); goto worker_cleanup; }
        SSL_set_fd(ssl, server_fd);
        {
            const char *sni = (a->tls_sni_host[0] != '\0') ? a->tls_sni_host : a->real_host;
            SSL_set_tlsext_host_name(ssl, sni);
        }

        if (SSL_connect(ssl) != 1) {
            char errbuf[256];
            ERR_error_string_n(ERR_get_error(), errbuf, sizeof(errbuf));
            DBLOG(session, "relay[%d]: SSL_connect failed: %s", client_fd, errbuf);
            goto worker_cleanup;
        }
        DBLOG(session, "relay[%d]: TLS OK cipher=%s", client_fd, SSL_get_cipher(ssl));
    }

    // 4. Bidirectional relay loop
    {
        int ssl_fd = SSL_get_fd(ssl);
        uint8_t buf[16384];

        while (session->relay_running) {
            if (SSL_pending(ssl) > 0) {
                int n = SSL_read(ssl, buf, sizeof(buf));
                if (n <= 0) break;
                for (int off = 0; off < n; ) {
                    int w = (int)write(client_fd, buf + off, (size_t)(n - off));
                    if (w <= 0) goto worker_done;
                    off += w;
                }
                continue;
            }

            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(client_fd, &rfds);
            FD_SET(ssl_fd, &rfds);
            int maxfd = (client_fd > ssl_fd ? client_fd : ssl_fd) + 1;
            struct timeval tv = {5, 0};
            int ns = select(maxfd, &rfds, NULL, NULL, &tv);
            if (ns < 0) break;
            if (ns == 0) continue;

            if (FD_ISSET(client_fd, &rfds)) {
                int n = (int)read(client_fd, buf, sizeof(buf));
                if (n <= 0) break;
                if (SSL_write(ssl, buf, n) <= 0) break;
            }
            if (FD_ISSET(ssl_fd, &rfds)) {
                int n = SSL_read(ssl, buf, sizeof(buf));
                if (n <= 0) break;
                for (int off = 0; off < n; ) {
                    int w = (int)write(client_fd, buf + off, (size_t)(n - off));
                    if (w <= 0) goto worker_done;
                    off += w;
                }
            }
        }
    }

worker_done:
worker_cleanup:
    if (ssl)       { SSL_shutdown(ssl); SSL_free(ssl); }
    if (ctx)       { SSL_CTX_free(ctx); }
    if (server_fd >= 0) close(server_fd);
    if (client_fd >= 0) close(client_fd);
    free(a);
    return NULL;
}

// Accept loop thread: accepts one connection per SPICE channel, spawns worker
static void *tls_relay_thread(void *arg) {
    TlsRelayArgs *tmpl = (TlsRelayArgs *)arg; // read-only template
    SpiceBridgeSession *session = tmpl->session;

    DBLOG(session, "relay: accept loop started");
    while (session->relay_running) {
        struct sockaddr_in addr;
        socklen_t addrlen = sizeof(addr);
        int cfd = accept(session->relay_listen_fd, (struct sockaddr *)&addr, &addrlen);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            break; // listener closed by disconnect
        }

        // Allocate per-worker args (copy of template + client fd)
        TlsRelayArgs *wa = malloc(sizeof(TlsRelayArgs));
        if (!wa) { close(cfd); continue; }
        *wa = *tmpl;
        wa->client_fd = cfd;

        pthread_t wt;
        if (pthread_create(&wt, NULL, tls_relay_worker, wa) != 0) {
            close(cfd);
            free(wa);
        } else {
            pthread_detach(wt);
        }
    }

    DBLOG(session, "relay: accept loop exited");
    free(tmpl);
    return NULL;
}

// macOS Catalyst: called when spice-glib needs a fd for a non-main channel.
// Creates a socketpair; gives one end to spice-glib, runs a TLS relay worker
// on the other end.  No bind/listen required — safe inside macOS App Sandbox.
#ifdef HAVE_SPICE
static void on_channel_open_fd(SpiceChannel *channel, int with_tls, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "open-fd: %s with_tls=%d",
          g_type_name(G_TYPE_FROM_INSTANCE(channel)), with_tls);

    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) {
        DBLOG(session, "open-fd: socketpair failed errno=%d", errno);
        spice_channel_open_fd(channel, -1);
        return;
    }

    TlsRelayArgs *wa = calloc(1, sizeof(TlsRelayArgs));
    if (!wa) {
        close(fds[0]); close(fds[1]);
        spice_channel_open_fd(channel, -1);
        return;
    }
    wa->session       = session;
    wa->real_tls_port = session->relay_tls_port;
    wa->has_proxy     = session->relay_has_proxy;
    wa->client_fd     = fds[1];
    strncpy(wa->real_host,   session->relay_host,       sizeof(wa->real_host)       - 1);
    strncpy(wa->proxy_host,  session->relay_proxy_host, sizeof(wa->proxy_host)      - 1);
    wa->proxy_port = session->relay_proxy_port;
    strncpy(wa->tls_sni_host, session->relay_tls_sni_host, sizeof(wa->tls_sni_host) - 1);
    wa->tls_sni_host[sizeof(wa->tls_sni_host) - 1] = '\0';

    pthread_t wt;
    if (pthread_create(&wt, NULL, tls_relay_worker, wa) != 0) {
        close(fds[0]); close(fds[1]);
        free(wa);
        spice_channel_open_fd(channel, -1);
        return;
    }
    pthread_detach(wt);

    DBLOG(session, "open-fd: relay worker fds[0]=%d(spice) fds[1]=%d(relay)", fds[0], fds[1]);
    spice_channel_open_fd(channel, fds[0]);
}
#endif // HAVE_SPICE

// ---------------------------------------------------------------------------
// Public API implementation

SpiceBridgeSession *spice_bridge_session_new(const SpiceBridgeCallbacks *callbacks) {
    SpiceBridgeSession *session = calloc(1, sizeof(SpiceBridgeSession));
    if (!session) return NULL;

    if (callbacks) {
        session->callbacks = *callbacks;
    }
    session->state = SPICE_BRIDGE_STATE_DISCONNECTED;
    pthread_mutex_init(&session->lock, NULL);
    session->relay_listen_fd  = -1;
    session->relay_running    = 0;
    session->relay_main_fd    = -1;
    session->relay_use_open_fd = 0;

#ifdef HAVE_SPICE
    BLOG("spice_bridge_session_new: HAVE_SPICE is active, creating session");

    // Disconnect synchronization — quit_loop waits until on_session_disconnected fires
    g_mutex_init(&session->disconnect_mutex);
    g_cond_init(&session->disconnect_cond);
    session->disconnect_notified = FALSE;

    // All sessions share the global default GLib context (NULL).
    // ensure_shared_loop() starts a single dedicated thread that runs
    // g_main_loop_run on that context — called later from spice_bridge_run_loop.
    session->spice_session = spice_session_new();
    session->clipboard_shared_files =
        g_hash_table_new_full(g_file_hash, bridge_file_equal_gconst, g_object_unref, g_free);

    {
        gchar *tmpl = g_strdup_printf("%s/pvespice-spice-XXXXXX", g_get_tmp_dir());
        if (g_mkdtemp(tmpl)) {
            session->clipboard_phodav_tmpdir = tmpl;
            g_object_set(session->spice_session,
                         "shared-dir", tmpl,
                         "share-dir-ro", FALSE,
                         NULL);
            (void)spice_session_get_webdav_server(session->spice_session);
            DBLOG(session, "clipboard WebDAV share-dir=%s", tmpl);
        } else {
            g_free(tmpl);
            DBLOG(session, "clipboard: g_mkdtemp failed; file-list host→guest disabled");
        }
    }

    g_signal_connect(session->spice_session, "channel-new",
                     G_CALLBACK(on_channel_new), session);
    g_signal_connect(session->spice_session, "channel-destroy",
                     G_CALLBACK(on_channel_destroy), session);
    g_signal_connect(session->spice_session, "disconnected",
                     G_CALLBACK(on_session_disconnected), session);

    // Capture internal spice-glib warnings/errors via the GLib log system
    g_log_set_handler("GSpice",   G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler("Spice",    G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler("GLib",     G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler("GLib-GIO", G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler(NULL,       G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);

    // Check if GIO has a working TLS backend — required for SPICE TLS
    GTlsBackend *tls_be = g_tls_backend_get_default();
    gboolean tls_ok = tls_be ? g_tls_backend_supports_tls(tls_be) : FALSE;
    DBLOG(session, "GIO TLS: backend=%s supports=%d",
          tls_be ? g_type_name(G_TYPE_FROM_INSTANCE(tls_be)) : "NONE", (int)tls_ok);
#endif

    return session;
}

void spice_bridge_session_free(SpiceBridgeSession *session) {
    if (!session) return;

    spice_bridge_disconnect(session);
    spice_bridge_quit_loop(session);

#ifdef HAVE_SPICE
    // Clear all Swift callbacks before GObject finalization to prevent
    // spice_session_dispose -> g_warn_message -> log_handler -> on_debug
    // from dispatching back into Swift while the view hierarchy is torn down.
    memset(&session->callbacks, 0, sizeof(session->callbacks));

    clipboard_file_bridge_cleanup_pre_session_unref(session);

    if (session->spice_session) {
        g_object_unref(session->spice_session);
        session->spice_session = NULL;
    }

    clipboard_file_bridge_delete_tmpdir(session);

    g_mutex_clear(&session->disconnect_mutex);
    g_cond_clear(&session->disconnect_cond);
#endif

    pthread_mutex_destroy(&session->lock);
    free(session);
}

bool spice_bridge_connect(SpiceBridgeSession *session,
                          const char *host,
                          int port,
                          int tls_port,
                          const char *password,
                          const char *ca_cert,
                          const char *host_subject,
                          const char *proxy) {
    if (!session || !host) return false;

    DBLOG(session, "connect host=%s port=%d tls=%d", host, port, tls_port);

    notify_state_change(session, SPICE_BRIDGE_STATE_CONNECTING);

#ifdef HAVE_SPICE
    if (tls_port > 0) {
        // ----------------------------------------------------------------
        // TLS relay path: GIO has no TLS backend (GDummyTlsBackend).
        // Relay does proxy CONNECT + OpenSSL TLS, presents plain TCP to spice-glib.
        //
        // iOS:           bind/listen on 127.0.0.1:0 works fine.
        // macOS Catalyst: bind/listen fails with EPERM in App Sandbox even with
        //                 network.server entitlement.  Use socketpair instead.
        // ----------------------------------------------------------------

        // Build relay args — common to both paths
        TlsRelayArgs *ra = calloc(1, sizeof(TlsRelayArgs));
        if (!ra) {
            notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
            return false;
        }
        ra->session = session;
        strncpy(ra->real_host, host, sizeof(ra->real_host) - 1);
        ra->real_tls_port = tls_port;
        ra->has_proxy = (proxy != NULL && proxy[0] != '\0');
        fill_tls_sni_from_subject(host_subject, ra->tls_sni_host, sizeof(ra->tls_sni_host));
        if (ra->tls_sni_host[0] == '\0') {
            strncpy(ra->tls_sni_host, host, sizeof(ra->tls_sni_host) - 1);
            ra->tls_sni_host[sizeof(ra->tls_sni_host) - 1] = '\0';
        }
        if (ra->has_proxy) {
            const char *p = strstr(proxy, "://");
            const char *h = p ? p + 3 : proxy;
            const char *col = strrchr(h, ':');
            if (col) {
                ra->proxy_port = atoi(col + 1);
                int hl = (int)(col - h);
                if (hl >= (int)sizeof(ra->proxy_host)) hl = (int)sizeof(ra->proxy_host) - 1;
                memcpy(ra->proxy_host, h, hl);
            } else {
                strncpy(ra->proxy_host, h, sizeof(ra->proxy_host) - 1);
                ra->proxy_port = 3128;
            }
        }

#if TARGET_OS_MACCATALYST
        // macOS Catalyst path: socketpair for main channel + open-fd for the rest
        int mfds[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, mfds) < 0) {
            DBLOG(session, "relay: socketpair failed errno=%d", errno);
            free(ra);
            notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
            return false;
        }
        ra->client_fd = mfds[1];
        session->relay_running    = 1;
        session->relay_use_open_fd = 1;
        session->relay_tls_port   = tls_port;
        session->relay_has_proxy  = ra->has_proxy;
        strncpy(session->relay_host,       ra->real_host,  sizeof(session->relay_host)       - 1);
        strncpy(session->relay_proxy_host, ra->proxy_host, sizeof(session->relay_proxy_host) - 1);
        session->relay_proxy_port = ra->proxy_port;
        strncpy(session->relay_tls_sni_host, ra->tls_sni_host, sizeof(session->relay_tls_sni_host) - 1);
        session->relay_tls_sni_host[sizeof(session->relay_tls_sni_host) - 1] = '\0';

        pthread_t rt;
        pthread_create(&rt, NULL, tls_relay_worker, ra);
        pthread_detach(rt);

        session->relay_main_fd = mfds[0];  // handed to spice-glib below via open_fd
        DBLOG(session, "relay: socketpair main_fd=%d relay_fd=%d -> %s:%d (proxy=%s:%d)",
              mfds[0], mfds[1], host, tls_port,
              ra->has_proxy ? ra->proxy_host : "none",
              ra->has_proxy ? ra->proxy_port : 0);
        if (password) {
            g_object_set(session->spice_session, "password", password, NULL);
        }

#else
        // iOS path: bind/listen on loopback
        int lfd = socket(AF_INET, SOCK_STREAM, 0);
        if (lfd < 0) {
            DBLOG(session, "relay: socket failed errno=%d", errno);
            free(ra);
            notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
            return false;
        }
        int one = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in la = {0};
        la.sin_family = AF_INET;
        la.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        la.sin_port = 0;
        if (bind(lfd, (struct sockaddr *)&la, sizeof(la)) < 0 ||
            listen(lfd, 16) < 0) {
            DBLOG(session, "relay: bind/listen failed errno=%d", errno);
            close(lfd);
            free(ra);
            notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
            return false;
        }
        socklen_t llen = sizeof(la);
        getsockname(lfd, (struct sockaddr *)&la, &llen);
        int relay_port = ntohs(la.sin_port);
        session->relay_listen_fd = lfd;
        DBLOG(session, "relay: listener on 127.0.0.1:%d -> %s:%d (proxy=%s)",
              relay_port, host, tls_port, proxy ? proxy : "none");

        session->relay_running = 1;
        pthread_t rt;
        pthread_create(&rt, NULL, tls_relay_thread, ra);
        pthread_detach(rt);

        g_object_set(session->spice_session,
                     "host", "127.0.0.1",
                     "port", g_strdup_printf("%d", relay_port),
                     NULL);
        if (password) {
            g_object_set(session->spice_session, "password", password, NULL);
        }
#endif // TARGET_OS_MACCATALYST

    } else {
        // ----------------------------------------------------------------
        // Plain (non-TLS) path — use spice-glib proxy/TLS handling as-is
        // ----------------------------------------------------------------
        g_object_set(session->spice_session,
                     "host", host,
                     "port", g_strdup_printf("%d", port),
                     NULL);
        if (password) {
            g_object_set(session->spice_session, "password", password, NULL);
        }
        if (ca_cert) {
            char ca_tmp[256] = {0};
            const char *tmpdir = g_get_tmp_dir();
            size_t tlen = strlen(tmpdir);
            if (tlen > 0 && tmpdir[tlen - 1] == '/')
                snprintf(ca_tmp, sizeof(ca_tmp), "%sspice_ca_XXXXXX.pem", tmpdir);
            else
                snprintf(ca_tmp, sizeof(ca_tmp), "%s/spice_ca_XXXXXX.pem", tmpdir);
            int fd = mkstemps(ca_tmp, 4);
            if (fd >= 0) {
                write(fd, ca_cert, strlen(ca_cert));
                close(fd);
                DBLOG(session, "ca-file=%s", ca_tmp);
                g_object_set(session->spice_session, "ca-file", ca_tmp, NULL);
            } else {
                DBLOG(session, "ca-file: failed to create temp file");
            }
        }
        if (host_subject) {
            g_object_set(session->spice_session, "cert-subject", host_subject, NULL);
        }
        if (proxy) {
            g_object_set(session->spice_session, "proxy", proxy, NULL);
        }
        g_object_set(session->spice_session, "verify", (guint)0, NULL);
        DBLOG(session, "verify=0 (TLS cert check disabled)");
    }

    gboolean success;
#if TARGET_OS_MACCATALYST
    if (session->relay_main_fd >= 0) {
        // macOS: provide main channel fd; spice-glib emits open-fd for other channels
        int fd = session->relay_main_fd;
        session->relay_main_fd = -1;
        success = spice_session_open_fd(session->spice_session, fd);
        DBLOG(session, "spice_session_open_fd(fd=%d)=%d", fd, success);
    } else {
        success = spice_session_connect(session->spice_session);
        DBLOG(session, "spice_session_connect=%d", success);
    }
#else
    success = spice_session_connect(session->spice_session);
    DBLOG(session, "spice_session_connect=%d", success);
#endif

    if (success) {
        notify_state_change(session, SPICE_BRIDGE_STATE_CONNECTED);
    } else {
        notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
    }
    return success;
#else
    // Stub: no SPICE library linked
    notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
    return false;
#endif
}

void spice_bridge_disconnect(SpiceBridgeSession *session) {
    if (!session) return;

#ifdef HAVE_SPICE
    session->clipboard_epoch++;
#endif

    // Stop relay accept loop by closing the listener fd
    session->relay_running = 0;
    if (session->relay_listen_fd >= 0) {
        close(session->relay_listen_fd);
        session->relay_listen_fd = -1;
    }
    // Per-channel worker threads are detached and will exit when their fds close

#ifdef HAVE_SPICE
    if (session->spice_session) {
        notify_state_change(session, SPICE_BRIDGE_STATE_DISCONNECTING);
        spice_session_disconnect(session->spice_session);
    }
#endif

    notify_state_change(session, SPICE_BRIDGE_STATE_DISCONNECTED);
}

SpiceBridgeState spice_bridge_get_state(const SpiceBridgeSession *session) {
    if (!session) return SPICE_BRIDGE_STATE_DISCONNECTED;
    return session->state;
}

void spice_bridge_key_press(SpiceBridgeSession *session, uint32_t scancode) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_key_press(session->inputs_channel, scancode);
    }
#endif
}

void spice_bridge_key_release(SpiceBridgeSession *session, uint32_t scancode) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_key_release(session->inputs_channel, scancode);
    }
#endif
}

void spice_bridge_mouse_position(SpiceBridgeSession *session,
                                  int32_t x, int32_t y,
                                  int32_t display_id,
                                  uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_position(session->inputs_channel, x, y, display_id, button_mask);
    }
#endif
}

void spice_bridge_mouse_motion(SpiceBridgeSession *session,
                                int32_t dx, int32_t dy,
                                uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_motion(session->inputs_channel, dx, dy, button_mask);
    }
#endif
}

#ifdef HAVE_SPICE
/**
 * Swift passes SPICE_MOUSE_BUTTON_MASK-style bits (1<<n). spice_inputs_* expects
 * SpiceMouseButton enum (LEFT=1, MIDDLE=2, RIGHT=3, …) for the first argument.
 * Only LEFT and MIDDLE happen to equal their mask bits; RIGHT/WHEEL/SIDE were wrong.
 */
static gint bridge_button_mask_to_spice_button(uint32_t mask)
{
    if (mask & (1u << 0)) return SPICE_MOUSE_BUTTON_LEFT;
    if (mask & (1u << 1)) return SPICE_MOUSE_BUTTON_MIDDLE;
    if (mask & (1u << 2)) return SPICE_MOUSE_BUTTON_RIGHT;
    if (mask & (1u << 3)) return SPICE_MOUSE_BUTTON_UP;
    if (mask & (1u << 4)) return SPICE_MOUSE_BUTTON_DOWN;
    if (mask & (1u << 5)) return SPICE_MOUSE_BUTTON_SIDE;
    if (mask & (1u << 6)) return SPICE_MOUSE_BUTTON_EXTRA;
    return SPICE_MOUSE_BUTTON_INVALID;
}
#endif

void spice_bridge_mouse_button_press(SpiceBridgeSession *session,
                                      uint32_t button,
                                      uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        gint sb = bridge_button_mask_to_spice_button(button);
        if (sb != SPICE_MOUSE_BUTTON_INVALID) {
            spice_inputs_button_press(session->inputs_channel, sb, (gint)button_mask);
        }
    }
#endif
}

void spice_bridge_mouse_button_release(SpiceBridgeSession *session,
                                        uint32_t button,
                                        uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        gint sb = bridge_button_mask_to_spice_button(button);
        if (sb != SPICE_MOUSE_BUTTON_INVALID) {
            spice_inputs_button_release(session->inputs_channel, sb, (gint)button_mask);
        }
    }
#endif
}

void spice_bridge_run_loop(SpiceBridgeSession *session) {
    if (!session) return;
    DBLOG(session, "run_loop: ensuring shared GLib loop is running");
#ifdef HAVE_SPICE
    ensure_shared_loop();
#endif
}

void spice_bridge_quit_loop(SpiceBridgeSession *session) {
    if (!session) return;
#ifdef HAVE_SPICE
    // Wait (up to 5 s) for on_session_disconnected to fire before the caller
    // proceeds to free the session.  Prevents use-after-free in GLib callbacks.
    g_mutex_lock(&session->disconnect_mutex);
    if (!session->disconnect_notified) {
        gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
        g_cond_wait_until(&session->disconnect_cond, &session->disconnect_mutex, deadline);
    }
    g_mutex_unlock(&session->disconnect_mutex);
    // The shared GLib loop is not stopped — it serves all sessions for the app lifetime.
#endif
}

void spice_bridge_record_send_data(SpiceBridgeSession *session,
                                    const uint8_t *data,
                                    size_t size,
                                    uint32_t time_ms) {
#ifdef HAVE_SPICE
    if (!session || !session->record_channel || !data || size == 0) return;
    spice_record_channel_send_data(session->record_channel,
                                   (gpointer)data, (gsize)size, (guint32)time_ms);
#endif
}

bool spice_bridge_get_display_info(const SpiceBridgeSession *session,
                                    int32_t *out_width,
                                    int32_t *out_height) {
    if (!session) return false;

    // Use lock to safely read display dimensions
    pthread_mutex_lock((pthread_mutex_t *)&session->lock);
    int32_t w = session->display_width;
    int32_t h = session->display_height;
    pthread_mutex_unlock((pthread_mutex_t *)&session->lock);

    if (w <= 0 || h <= 0) return false;

    if (out_width) *out_width = w;
    if (out_height) *out_height = h;
    return true;
}

#ifdef HAVE_SPICE
typedef struct {
    SpiceBridgeSession *session;
    gchar **paths;
    SpiceBridgeSendFilesFinishedCallback on_finished;
    void *fn_ctx;
} SpiceBridgeSendFilesOp;

static void spice_bridge_send_files_op_free(SpiceBridgeSendFilesOp *op)
{
    if (!op)
        return;
    g_strfreev(op->paths);
    g_free(op);
}

/* spice_main_channel_file_copy_async 的 GFileProgressCallback：便于确认是否在读字节 */
static void bridge_file_copy_progress(goffset current_num_bytes,
                                       goffset total_num_bytes,
                                       gpointer user_data)
{
    (void)user_data;
    printf("[SpiceBridge] Transfer progress: %lld / %lld\n",
           (long long)current_num_bytes, (long long)total_num_bytes);
}

static void on_file_copy_finished(GObject *source_obj, GAsyncResult *res, gpointer user_data)
{
    SpiceBridgeSendFilesOp *op = user_data;
    GError *err = NULL;
    gboolean ok = spice_main_channel_file_copy_finish(SPICE_MAIN_CHANNEL(source_obj), res, &err);
    gchar *emsg_dup = NULL;

    if (!ok) {
        if (err != NULL) {
            printf("[SpiceBridge] File transfer failed: %s (code: %d)\n",
                   err->message ? err->message : "(null message)", err->code);
            emsg_dup = g_strdup(err->message ? err->message : "file transfer failed");
            g_error_free(err);
            err = NULL;
        } else {
            printf("[SpiceBridge] File transfer failed: no GError (spice_main_channel_file_copy_finish returned FALSE)\n");
            emsg_dup = g_strdup("file transfer failed (no GError)");
        }
    } else {
        if (err != NULL) {
            printf("[SpiceBridge] File transfer: unexpected GError on success: %s (code: %d)\n",
                   err->message ? err->message : "(null)", err->code);
            g_error_free(err);
            err = NULL;
        } else {
            printf("[SpiceBridge] File transfer completed successfully.\n");
        }
    }

#if defined(__APPLE__)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (op->on_finished)
            op->on_finished(op->fn_ctx, ok ? 1 : 0, emsg_dup);
        g_free(emsg_dup);
        spice_bridge_send_files_op_free(op);
    });
#else
    if (op->on_finished)
        op->on_finished(op->fn_ctx, ok ? 1 : 0, emsg_dup);
    g_free(emsg_dup);
    spice_bridge_send_files_op_free(op);
#endif
}

static void send_files_fail_async(SpiceBridgeSendFilesOp *op, const char *msg)
{
#if defined(__APPLE__)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (op->on_finished)
            op->on_finished(op->fn_ctx, 0, msg);
        spice_bridge_send_files_op_free(op);
    });
#else
    if (op->on_finished)
        op->on_finished(op->fn_ctx, 0, msg);
    spice_bridge_send_files_op_free(op);
#endif
}

static gboolean send_files_invoke_fn(gpointer user_data)
{
    SpiceBridgeSendFilesOp *op = user_data;
    SpiceBridgeSession *session = op->session;
    gint count, i;
    GFile **files;

    if (!session->main_channel || !op->paths) {
        send_files_fail_async(op, "SPICE main channel not ready");
        return G_SOURCE_REMOVE;
    }

    count = (gint)g_strv_length(op->paths);
    if (count <= 0) {
        send_files_fail_async(op, "no files selected");
        return G_SOURCE_REMOVE;
    }

    /* vd_agent.h 无 VD_AGENT_CAP_FILE_XFER；来宾宣告 VD_AGENT_CAP_FILE_XFER_DISABLED 时 spice-glib 直接拒绝传输 */
    {
        gboolean cap_xfer_disabled = spice_main_channel_agent_test_capability(session->main_channel,
                                                                              VD_AGENT_CAP_FILE_XFER_DISABLED);
        gboolean cap_detailed = spice_main_channel_agent_test_capability(session->main_channel,
                                                                         VD_AGENT_CAP_FILE_XFER_DETAILED_ERRORS);
        gboolean can_transfer = !cap_xfer_disabled;
        printf("[SpiceBridge] File xfer precheck: !VD_AGENT_CAP_FILE_XFER_DISABLED => allowed: %s\n",
               can_transfer ? "YES" : "NO");
        printf("[SpiceBridge] VD_AGENT_CAP_FILE_XFER_DISABLED (spice-glib blocks when YES): %s\n",
               cap_xfer_disabled ? "YES" : "NO");
        printf("[SpiceBridge] VD_AGENT_CAP_FILE_XFER_DETAILED_ERRORS: %s\n", cap_detailed ? "YES" : "NO");
    }

    /* spice_file_transfer_task_create_tasks() 以 files[i]!=NULL 遍历，末尾必须为 NULL */
    files = g_new0(GFile *, (gsize)count + 1);
    for (i = 0; i < count; i++) {
        const gchar *p = op->paths[i];
        gboolean exists;
        GError *read_err = NULL;
        GFileInfo *info;

        files[i] = bridge_g_file_new_for_uri_or_path(p);
        if (!files[i]) {
            gint j;
            printf("[SpiceBridge] ERROR: bridge_g_file_new_for_uri_or_path failed for: %s\n",
                   p ? p : "(null)");
            for (j = 0; j < i; j++)
                g_clear_object(&files[j]);
            g_free(files);
            send_files_fail_async(op, "invalid path (empty or unsupported)");
            return G_SOURCE_REMOVE;
        }

        exists = g_file_query_exists(files[i], NULL);
        printf("[SpiceBridge] Checking file: %s -> exists: %s\n", p ? p : "(null)", exists ? "YES" : "NO");

        info = g_file_query_info(files[i], G_FILE_ATTRIBUTE_STANDARD_SIZE,
                                 G_FILE_QUERY_INFO_NONE, NULL, &read_err);
        if (read_err) {
            printf("[SpiceBridge] ERROR reading file info: %s\n", read_err->message);
            g_error_free(read_err);
        } else {
            printf("[SpiceBridge] File info OK, size: %lld\n",
                   (long long)g_file_info_get_size(info));
            g_object_unref(info);
        }
    }
    files[count] = NULL;

    spice_main_channel_file_copy_async(session->main_channel, files, G_FILE_COPY_NONE,
                                       NULL,
                                       bridge_file_copy_progress, NULL,
                                       on_file_copy_finished, op);
    for (i = 0; i < count; i++)
        g_object_unref(files[i]);
    g_free(files);
    return G_SOURCE_REMOVE;
}
#endif /* HAVE_SPICE */

void spice_bridge_send_local_files_to_guest(SpiceBridgeSession *session,
                                            const char *const *posix_paths,
                                            int n_paths,
                                            SpiceBridgeSendFilesFinishedCallback on_finished,
                                            void *context)
{
#ifdef HAVE_SPICE
    SpiceBridgeSendFilesOp *op;
    int i;

    if (!session || !posix_paths || n_paths <= 0) {
        if (on_finished) {
#if defined(__APPLE__)
            dispatch_async(dispatch_get_main_queue(), ^{
                on_finished(context, 0, "invalid arguments");
            });
#else
            on_finished(context, 0, "invalid arguments");
#endif
        }
        return;
    }

    op = g_new0(SpiceBridgeSendFilesOp, 1);
    op->session = session;
    op->paths = g_new0(gchar *, (gsize)n_paths + 1);
    for (i = 0; i < n_paths; i++) {
        if (!posix_paths[i]) {
            g_strfreev(op->paths);
            g_free(op);
            if (on_finished) {
#if defined(__APPLE__)
                dispatch_async(dispatch_get_main_queue(), ^{
                    on_finished(context, 0, "invalid path");
                });
#else
                on_finished(context, 0, "invalid path");
#endif
            }
            return;
        }
        op->paths[i] = g_strdup(posix_paths[i]);
    }
    op->on_finished = on_finished;
    op->fn_ctx = context;
    g_main_context_invoke(NULL, send_files_invoke_fn, op);
#else
    (void)session;
    (void)posix_paths;
    (void)n_paths;
    if (on_finished)
        on_finished(context, 0, "SPICE not available");
#endif
}

void spice_bridge_clipboard_host_pasteboard_changed(SpiceBridgeSession *session)
{
#ifdef HAVE_SPICE
    HostClipboardIdle *h;

    if (!session)
        return;

    h = malloc(sizeof(HostClipboardIdle));
    if (!h)
        return;
    h->session = session;
    h->epoch = session->clipboard_epoch;
    g_main_context_invoke(NULL, host_clipboard_idle_fn, h);
#else
    (void)session;
#endif
}

void spice_bridge_set_clipboard_files(SpiceBridgeSession *session,
                                      const char *const *uris,
                                      int count)
{
#ifdef HAVE_SPICE
    SetClipboardFilesOp *op;
    gint i;

    if (!session || count < 0)
        return;

    op = g_new0(SetClipboardFilesOp, 1);
    op->session = session;
    op->count = count;
    if (count > 0 && uris) {
        op->uris = g_new0(gchar *, (gsize)count + 1);
        for (i = 0; i < count; i++)
            op->uris[i] = g_strdup(uris[i] ? uris[i] : "");
    }
    g_main_context_invoke(NULL, set_clipboard_files_invoke, op);
#else
    (void)session;
    (void)uris;
    (void)count;
#endif
}

char *spice_bridge_get_webdav_base_url_malloc(SpiceBridgeSession *session)
{
#ifdef HAVE_SPICE
    PhodavServer *pd;
    SoupServer *soup;
    GSList *uris;

    if (!session || !session->spice_session)
        return NULL;
    pd = spice_session_get_webdav_server(session->spice_session);
    if (!pd)
        return NULL;
    soup = phodav_server_get_soup_server(pd);
    if (!soup)
        return NULL;
    uris = soup_server_get_uris(soup);
    if (!uris)
        return NULL;

    for (GSList *l = uris; l; l = l->next) {
        GUri *u = (GUri *)l->data;
        gchar *s;
        gchar *with_slash;
        char *out;

        if (!u)
            continue;
        s = g_uri_to_string(u);
        if (!s)
            continue;
        if (g_str_has_suffix(s, "/"))
            with_slash = g_strdup(s);
        else
            with_slash = g_strconcat(s, "/", NULL);
        g_free(s);
        out = strdup(with_slash);
        g_free(with_slash);
        g_slist_free_full(uris, (GDestroyNotify)g_uri_unref);
        return out;
    }
    g_slist_free_full(uris, (GDestroyNotify)g_uri_unref);
    return NULL;
#else
    (void)session;
    return NULL;
#endif
}
