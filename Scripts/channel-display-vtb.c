/* channel-display-vtb.c
 *
 * VideoToolbox H.264/H.265 hardware decoder for SPICE streams on Apple platforms.
 * Used when building without GStreamer (e.g. iOS).
 *
 * Implements the same VideoDecoder interface as channel-display-mjpeg.c:
 *   - gstvideo_has_codec()      reports H264 and H265 support to libspice
 *   - create_gstreamer_decoder() returns a VtbDecoder for H264/H265
 *
 * Frame timing follows the MJPEG decoder pattern: GLib timer fires at the
 * target mm_time, VTDecompressionSession decodes synchronously, decoded BGRA
 * pixels are passed to stream_display_frame() from the GLib main context.
 */

#include "config.h"
#include <string.h>
#include <stdlib.h>
#include "spice-client.h"
#include "spice-common.h"
#include "spice-channel-priv.h"
#include "channel-display-priv.h"

#ifndef __APPLE__

/* Non-Apple build: behave like the stub */
gboolean gstvideo_has_codec(int codec_type) { (void)codec_type; return FALSE; }
VideoDecoder *create_gstreamer_decoder(int codec_type, display_stream *stream)
    { (void)codec_type; (void)stream; return NULL; }

#else /* __APPLE__ */

#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <pthread.h>

/* ============================================================
 * Per-channel video frame callback registry
 * ============================================================ */

typedef struct {
    SpiceChannel *channel;
    void (*cb)(CVImageBufferRef pixbuf, void *ctx);
    void *ctx;
} VtbCbEntry;
#define VTB_MAX_CB 8
static VtbCbEntry      s_vtb_cb[VTB_MAX_CB];
static int             s_vtb_cb_count = 0;
static pthread_mutex_t s_vtb_cb_mu    = PTHREAD_MUTEX_INITIALIZER;

void vtb_register_video_callback(SpiceChannel *ch,
                                  void (*cb)(CVImageBufferRef, void *), void *ctx)
{
    pthread_mutex_lock(&s_vtb_cb_mu);
    for (int i = 0; i < s_vtb_cb_count; i++) {
        if (s_vtb_cb[i].channel == ch) {
            s_vtb_cb[i].cb = cb; s_vtb_cb[i].ctx = ctx;
            pthread_mutex_unlock(&s_vtb_cb_mu); return;
        }
    }
    if (s_vtb_cb_count < VTB_MAX_CB) {
        s_vtb_cb[s_vtb_cb_count++] = (VtbCbEntry){ ch, cb, ctx };
    }
    pthread_mutex_unlock(&s_vtb_cb_mu);
}

void vtb_unregister_video_callback(SpiceChannel *ch)
{
    pthread_mutex_lock(&s_vtb_cb_mu);
    for (int i = 0; i < s_vtb_cb_count; i++) {
        if (s_vtb_cb[i].channel == ch) {
            s_vtb_cb[i] = s_vtb_cb[--s_vtb_cb_count];
            break;
        }
    }
    pthread_mutex_unlock(&s_vtb_cb_mu);
}

static void vtb_call_video_callback(SpiceChannel *ch, CVImageBufferRef pixbuf)
{
    pthread_mutex_lock(&s_vtb_cb_mu);
    for (int i = 0; i < s_vtb_cb_count; i++) {
        if (s_vtb_cb[i].channel == ch) {
            void (*cb)(CVImageBufferRef, void*) = s_vtb_cb[i].cb;
            void *ctx = s_vtb_cb[i].ctx;
            pthread_mutex_unlock(&s_vtb_cb_mu);
            cb(pixbuf, ctx);
            return;
        }
    }
    pthread_mutex_unlock(&s_vtb_cb_mu);
}

/* ============================================================
 * Annex-B byte-stream NAL unit parsing
 * ============================================================ */

/** Descriptor for one NAL unit found inside an Annex-B buffer.
 *  Points into the original buffer (no copy). */
typedef struct {
    const uint8_t *data;
    uint32_t       len;
} NalDesc;

/** Find the next Annex-B start code (00 00 01 or 00 00 00 01) in buf[pos..].
 *  Returns the byte offset of the start code, or -1 if not found.
 *  *sc_len is set to 3 or 4. */
static int annexb_find_sc(const uint8_t *buf, uint32_t buf_len,
                          uint32_t pos, int *sc_len)
{
    while (pos + 2 < buf_len) {
        if (buf[pos] == 0x00 && buf[pos + 1] == 0x00) {
            if (buf[pos + 2] == 0x01) {
                *sc_len = 3;
                return (int)pos;
            }
            if (pos + 3 < buf_len && buf[pos + 2] == 0x00 && buf[pos + 3] == 0x01) {
                *sc_len = 4;
                return (int)pos;
            }
        }
        pos++;
    }
    return -1;
}

/** Parse all NAL units in an Annex-B buffer.
 *  Fills out_nals[0..max_nals-1]; returns actual count. */
static int parse_annexb_nals(const uint8_t *buf, uint32_t buf_len,
                              NalDesc *out_nals, int max_nals)
{
    int    count    = 0;
    int    sc_len   = 0;
    int    sc_start = annexb_find_sc(buf, buf_len, 0, &sc_len);

    while (sc_start >= 0 && count < max_nals) {
        uint32_t nal_start = (uint32_t)sc_start + (uint32_t)sc_len;
        int      sc2_len   = 0;
        int      sc2_start = annexb_find_sc(buf, buf_len, nal_start, &sc2_len);
        uint32_t nal_end   = (sc2_start >= 0) ? (uint32_t)sc2_start : buf_len;

        if (nal_end > nal_start) {
            out_nals[count].data = buf + nal_start;
            out_nals[count].len  = nal_end - nal_start;
            count++;
        }

        if (sc2_start < 0) break;
        sc_start = sc2_start;
        sc_len   = sc2_len;
    }
    return count;
}

/* H.264 NAL unit types (bottom 5 bits of first byte) */
static inline int h264_nal_type(const NalDesc *n)
    { return n->len > 0 ? (n->data[0] & 0x1F) : 0; }

/* H.265 NAL unit type (bits [1..6] of first byte: (data[0] >> 1) & 0x3F) */
static inline int h265_nal_type(const NalDesc *n)
    { return n->len > 0 ? ((n->data[0] >> 1) & 0x3F) : 0; }

#define H264_NAL_SPS       7
#define H264_NAL_PPS       8

#define H265_NAL_VPS_NUT   32
#define H265_NAL_SPS_NUT   33
#define H265_NAL_PPS_NUT   34

/* ============================================================
 * Annex-B → AVCC conversion
 * ============================================================ */

static inline void write_be32(uint8_t *p, uint32_t v)
{
    p[0] = (v >> 24) & 0xFF;
    p[1] = (v >> 16) & 0xFF;
    p[2] = (v >>  8) & 0xFF;
    p[3] =  v        & 0xFF;
}

/** Convert Annex-B NAL units to AVCC format (4-byte big-endian length prefix).
 *  Parameter-set NALs (SPS/PPS/VPS) are excluded — they live in the format
 *  description, not in the sample buffer.
 *  Returns a g_malloc'd buffer; caller must g_free().  *out_len set to size.
 *  Returns NULL if there are no slice NALs. */
static uint8_t *annexb_to_avcc(const NalDesc *nals, int nal_count,
                                int codec_type, uint32_t *out_len)
{
    uint32_t total = 0;

    for (int i = 0; i < nal_count; i++) {
        gboolean skip;
        if (codec_type == SPICE_VIDEO_CODEC_TYPE_H264) {
            int t = h264_nal_type(&nals[i]);
            skip = (t == H264_NAL_SPS || t == H264_NAL_PPS);
        } else {
            int t = h265_nal_type(&nals[i]);
            skip = (t == H265_NAL_VPS_NUT || t == H265_NAL_SPS_NUT ||
                    t == H265_NAL_PPS_NUT);
        }
        if (!skip) total += 4 + nals[i].len;
    }

    if (total == 0) return NULL;

    uint8_t *avcc = g_malloc(total);
    uint8_t *p    = avcc;

    for (int i = 0; i < nal_count; i++) {
        gboolean skip;
        if (codec_type == SPICE_VIDEO_CODEC_TYPE_H264) {
            int t = h264_nal_type(&nals[i]);
            skip = (t == H264_NAL_SPS || t == H264_NAL_PPS);
        } else {
            int t = h265_nal_type(&nals[i]);
            skip = (t == H265_NAL_VPS_NUT || t == H265_NAL_SPS_NUT ||
                    t == H265_NAL_PPS_NUT);
        }
        if (!skip) {
            write_be32(p, nals[i].len);
            p += 4;
            memcpy(p, nals[i].data, nals[i].len);
            p += nals[i].len;
        }
    }

    *out_len = total;
    return avcc;
}

/* ============================================================
 * VtbDecoder
 * ============================================================ */

typedef struct VtbDecoder {
    VideoDecoder               base;

    /* Cached parameter sets (set when first IDR is seen) */
    uint8_t  *sps;      uint32_t sps_len;
    uint8_t  *pps;      uint32_t pps_len;
    uint8_t  *vps;      uint32_t vps_len;   /* HEVC only */

    /* VideoToolbox objects */
    CMVideoFormatDescriptionRef fmt_desc;
    VTDecompressionSessionRef   session;

    /* NV12 fast path: retained CVPixelBuffer from decode callback */
    gboolean          use_nv12;
    CVImageBufferRef  decoded_pixbuf;   /* retained; NULL if not decoded yet */

    /* BGRA fallback: scratch buffer filled by the decode callback */
    uint8_t  *out_frame;
    uint32_t  out_frame_size;
    uint32_t  out_width;
    uint32_t  out_height;
    gboolean  decode_ok;        /* set TRUE by callback on success */

    /* Frame queue (same timing pattern as channel-display-mjpeg.c) */
    GQueue     *msgq;
    SpiceFrame *cur_frame;
    guint       timer_id;
} VtbDecoder;

/* ============================================================
 * VideoToolbox decode callback — fires from a VT internal thread
 * ============================================================ */

static void vtb_decode_callback(void *decomp_ref,
                                 void *frame_ref,
                                 OSStatus status,
                                 VTDecodeInfoFlags info_flags,
                                 CVImageBufferRef image_buf,
                                 CMTime pts,
                                 CMTime duration)
{
    (void)frame_ref; (void)info_flags; (void)pts; (void)duration;

    VtbDecoder *decoder = (VtbDecoder *)decomp_ref;

    if (status != noErr || !image_buf) {
        SPICE_DEBUG("VTB decode callback: error %d", (int)status);
        decoder->decode_ok = FALSE;
        return;
    }

    if (decoder->use_nv12) {
        /* NV12 fast path: retain the CVPixelBuffer, hand to GLib thread */
        if (decoder->decoded_pixbuf) CVPixelBufferRelease(decoder->decoded_pixbuf);
        decoder->decoded_pixbuf = (CVImageBufferRef)CVPixelBufferRetain(image_buf);
        decoder->decode_ok = TRUE;
    } else {
        /* BGRA fallback: existing row-by-row memcpy */
        CVPixelBufferLockBaseAddress(image_buf, kCVPixelBufferLock_ReadOnly);

        uint32_t width  = (uint32_t)CVPixelBufferGetWidth(image_buf);
        uint32_t height = (uint32_t)CVPixelBufferGetHeight(image_buf);
        size_t   stride = CVPixelBufferGetBytesPerRow(image_buf);
        uint8_t *src    = (uint8_t *)CVPixelBufferGetBaseAddress(image_buf);

        uint32_t needed = width * height * 4;
        if (needed > decoder->out_frame_size) {
            g_free(decoder->out_frame);
            decoder->out_frame      = g_malloc(needed);
            decoder->out_frame_size = needed;
        }

        uint8_t *dst = decoder->out_frame;
        for (uint32_t y = 0; y < height; y++) {
            memcpy(dst + y * width * 4, src + y * stride, width * 4);
        }

        CVPixelBufferUnlockBaseAddress(image_buf, kCVPixelBufferLock_ReadOnly);

        decoder->out_width  = width;
        decoder->out_height = height;
        decoder->decode_ok  = TRUE;
    }
}

/* ============================================================
 * Session management
 * ============================================================ */

/** Create (or recreate) the VTDecompressionSession from stored parameter sets. */
static gboolean vtb_create_session(VtbDecoder *decoder)
{
    /* Release any existing objects */
    if (decoder->session) {
        VTDecompressionSessionInvalidate(decoder->session);
        CFRelease(decoder->session);
        decoder->session = NULL;
    }
    if (decoder->fmt_desc) {
        CFRelease(decoder->fmt_desc);
        decoder->fmt_desc = NULL;
    }

    OSStatus status;
    int codec = decoder->base.codec_type;

    if (codec == SPICE_VIDEO_CODEC_TYPE_H264) {
        if (!decoder->sps || !decoder->pps) return FALSE;

        const uint8_t *params[2] = { decoder->sps,     decoder->pps     };
        size_t         sizes[2]  = { decoder->sps_len, decoder->pps_len };

        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault,
            2, params, sizes,
            4,               /* AVCC length prefix size */
            &decoder->fmt_desc);

    } else {
        /* HEVC — requires iOS 11+, but our deployment target is 15.0 */
        if (!decoder->vps || !decoder->sps || !decoder->pps) return FALSE;

        const uint8_t *params[3] = { decoder->vps,     decoder->sps,
                                     decoder->pps                     };
        size_t         sizes[3]  = { decoder->vps_len, decoder->sps_len,
                                     decoder->pps_len                 };

        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault,
            3, params, sizes,
            4,               /* AVCC length prefix size */
            NULL,            /* extensions */
            &decoder->fmt_desc);
    }

    if (status != noErr) {
        SPICE_DEBUG("VTB: CMVideoFormatDescriptionCreate failed: %d", (int)status);
        return FALSE;
    }

    /* Check if a video callback is registered → use NV12 zero-copy fast path */
    gboolean has_cb = FALSE;
    pthread_mutex_lock(&s_vtb_cb_mu);
    for (int i = 0; i < s_vtb_cb_count; i++) {
        if (s_vtb_cb[i].channel == decoder->base.stream->channel) { has_cb = TRUE; break; }
    }
    pthread_mutex_unlock(&s_vtb_cb_mu);
    decoder->use_nv12 = has_cb;

    CFMutableDictionaryRef pb_attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    SInt32 fmt_val = has_cb
        ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   /* NV12 fast path */
        : kCVPixelFormatType_32BGRA;                        /* BGRA fallback  */
    CFNumberRef fmt_num = CFNumberCreate(kCFAllocatorDefault,
                                         kCFNumberSInt32Type, &fmt_val);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferPixelFormatTypeKey, fmt_num);
    CFRelease(fmt_num);

    VTDecompressionOutputCallbackRecord cb = {
        .decompressionOutputCallback = vtb_decode_callback,
        .decompressionOutputRefCon   = decoder,
    };

    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        decoder->fmt_desc,
        NULL,       /* decoder specification (let VT choose hardware/software) */
        pb_attrs,
        &cb,
        &decoder->session);

    CFRelease(pb_attrs);

    if (status != noErr) {
        SPICE_DEBUG("VTB: VTDecompressionSessionCreate failed: %d", (int)status);
        CFRelease(decoder->fmt_desc);
        decoder->fmt_desc = NULL;
        return FALSE;
    }

    SPICE_DEBUG("VTB: created %s decode session",
                codec == SPICE_VIDEO_CODEC_TYPE_H264 ? "H.264" : "H.265");
    return TRUE;
}

/* ============================================================
 * Frame decode  (called from GLib main context via g_timeout_add)
 * ============================================================ */

/** Extract parameter sets from NAL units, recreating session if they changed.
 *  Returns TRUE if session is ready for decoding. */
static gboolean vtb_update_params(VtbDecoder *decoder,
                                   const NalDesc *nals, int nal_count)
{
    int    codec         = decoder->base.codec_type;
    gboolean params_changed = FALSE;

    for (int i = 0; i < nal_count; i++) {
        if (codec == SPICE_VIDEO_CODEC_TYPE_H264) {
            int t = h264_nal_type(&nals[i]);
            if (t == H264_NAL_SPS) {
                if (!decoder->sps || decoder->sps_len != nals[i].len ||
                        memcmp(decoder->sps, nals[i].data, nals[i].len) != 0) {
                    g_free(decoder->sps);
                    decoder->sps     = g_memdup(nals[i].data, nals[i].len);
                    decoder->sps_len = nals[i].len;
                    params_changed   = TRUE;
                }
            } else if (t == H264_NAL_PPS) {
                if (!decoder->pps || decoder->pps_len != nals[i].len ||
                        memcmp(decoder->pps, nals[i].data, nals[i].len) != 0) {
                    g_free(decoder->pps);
                    decoder->pps     = g_memdup(nals[i].data, nals[i].len);
                    decoder->pps_len = nals[i].len;
                    params_changed   = TRUE;
                }
            }
        } else {
            int t = h265_nal_type(&nals[i]);
            if (t == H265_NAL_VPS_NUT) {
                if (!decoder->vps || decoder->vps_len != nals[i].len ||
                        memcmp(decoder->vps, nals[i].data, nals[i].len) != 0) {
                    g_free(decoder->vps);
                    decoder->vps     = g_memdup(nals[i].data, nals[i].len);
                    decoder->vps_len = nals[i].len;
                    params_changed   = TRUE;
                }
            } else if (t == H265_NAL_SPS_NUT) {
                if (!decoder->sps || decoder->sps_len != nals[i].len ||
                        memcmp(decoder->sps, nals[i].data, nals[i].len) != 0) {
                    g_free(decoder->sps);
                    decoder->sps     = g_memdup(nals[i].data, nals[i].len);
                    decoder->sps_len = nals[i].len;
                    params_changed   = TRUE;
                }
            } else if (t == H265_NAL_PPS_NUT) {
                if (!decoder->pps || decoder->pps_len != nals[i].len ||
                        memcmp(decoder->pps, nals[i].data, nals[i].len) != 0) {
                    g_free(decoder->pps);
                    decoder->pps     = g_memdup(nals[i].data, nals[i].len);
                    decoder->pps_len = nals[i].len;
                    params_changed   = TRUE;
                }
            }
        }
    }

    if (params_changed || !decoder->session) {
        return vtb_create_session(decoder);
    }
    return decoder->session != NULL;
}

/** Decode one SpiceFrame with VideoToolbox and push pixels via stream_display_frame(). */
static void vtb_decode_frame(VtbDecoder *decoder, SpiceFrame *frame)
{
    /* Parse Annex-B NAL units */
    NalDesc nals[64];
    int nal_count = parse_annexb_nals(frame->data, frame->size,
                                      nals, G_N_ELEMENTS(nals));
    if (nal_count == 0) {
        SPICE_DEBUG("VTB: no NAL units in frame, skipping");
        return;
    }

    /* Update parameter sets, (re)create session if needed */
    if (!vtb_update_params(decoder, nals, nal_count)) {
        SPICE_DEBUG("VTB: session not ready, dropping frame");
        return;
    }

    /* Convert slice NALs to AVCC format */
    uint32_t avcc_len  = 0;
    uint8_t *avcc_data = annexb_to_avcc(nals, nal_count,
                                         decoder->base.codec_type, &avcc_len);
    if (!avcc_data) {
        /* Frame contains only parameter sets (no slice data) — normal on IDR prep */
        return;
    }

    /* Wrap AVCC data in CMBlockBuffer.
     * kCFAllocatorDefault uses malloc/free, compatible with g_malloc on Apple. */
    CMBlockBufferRef block_buf = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        avcc_data, avcc_len,
        kCFAllocatorDefault,    /* releases avcc_data via free() when done */
        NULL, 0, avcc_len,
        0,
        &block_buf);

    if (status != noErr) {
        g_free(avcc_data);
        SPICE_DEBUG("VTB: CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        return;
    }
    /* avcc_data is now owned by block_buf */

    /* Create CMSampleBuffer (1 sample, no explicit timing — VT uses decode order) */
    CMSampleBufferRef sample_buf = NULL;
    const size_t sample_size = avcc_len;
    status = CMSampleBufferCreate(
        kCFAllocatorDefault,
        block_buf,
        TRUE,           /* dataReady */
        NULL, NULL,     /* no makeDataReadyCallback */
        decoder->fmt_desc,
        1,              /* numSamples */
        0, NULL,        /* numSampleTimingEntries, sampleTimingArray */
        1, &sample_size,
        &sample_buf);

    CFRelease(block_buf);

    if (status != noErr) {
        SPICE_DEBUG("VTB: CMSampleBufferCreate failed: %d", (int)status);
        return;
    }

    /* Decode synchronously (flags = 0: no async, no temporal reordering).
     * VTDecompressionSessionWaitForAsynchronousFrames flushes any hardware
     * pipeline to ensure the callback fires before we proceed. */
    decoder->decode_ok = FALSE;
    VTDecodeInfoFlags info_flags = 0;
    status = VTDecompressionSessionDecodeFrame(
        decoder->session,
        sample_buf,
        0,      /* decodeFlags */
        NULL,   /* sourceFrameRefCon */
        &info_flags);

    CFRelease(sample_buf);

    if (status != noErr) {
        SPICE_DEBUG("VTB: VTDecompressionSessionDecodeFrame failed: %d", (int)status);
        return;
    }

    VTDecompressionSessionWaitForAsynchronousFrames(decoder->session);

    if (decoder->use_nv12 && decoder->decoded_pixbuf) {
        /* Fast path: call Swift callback directly with CVPixelBuffer */
        vtb_call_video_callback(decoder->base.stream->channel, decoder->decoded_pixbuf);
        CVPixelBufferRelease(decoder->decoded_pixbuf);
        decoder->decoded_pixbuf = NULL;
    } else if (!decoder->use_nv12 && decoder->decode_ok) {
        /* Fallback: existing BGRA path via stream_display_frame */
        stream_display_frame(decoder->base.stream, frame,
                             decoder->out_width, decoder->out_height,
                             SPICE_UNKNOWN_STRIDE, decoder->out_frame);
    } else {
        SPICE_DEBUG("VTB: callback reported decode failure");
    }
}

/* ============================================================
 * VideoDecoder interface (mirrors channel-display-mjpeg.c)
 * ============================================================ */

static void vtb_decoder_schedule(VtbDecoder *decoder);

static gboolean vtb_timer_cb(gpointer user_data)
{
    VtbDecoder *decoder = (VtbDecoder *)user_data;
    decoder->timer_id = 0;

    if (decoder->cur_frame) {
        vtb_decode_frame(decoder, decoder->cur_frame);
        g_clear_pointer(&decoder->cur_frame, spice_frame_free);
    }

    vtb_decoder_schedule(decoder);
    return G_SOURCE_REMOVE;
}

static void vtb_decoder_schedule(VtbDecoder *decoder)
{
    if (decoder->timer_id) return;

    guint32 now = stream_get_time(decoder->base.stream);

    decoder->cur_frame = NULL;
    while (TRUE) {
        SpiceFrame *frame = g_queue_pop_head(decoder->msgq);
        if (!frame) break;

        if (spice_mmtime_diff(now, frame->mm_time) <= 0) {
            /* Frame is not late: schedule it */
            guint32 delay    = frame->mm_time - now;
            decoder->cur_frame = frame;
            decoder->timer_id  = g_timeout_add(delay, vtb_timer_cb, decoder);
            return;
        }

        /* Frame is late: drop */
        SPICE_DEBUG("VTB: dropping frame late by %u ms",
                    now - frame->mm_time);
        stream_dropped_frame_on_playback(decoder->base.stream);
        spice_frame_free(frame);
    }
}

static void vtb_decoder_drop_queue(VtbDecoder *decoder)
{
    if (decoder->timer_id) {
        g_source_remove(decoder->timer_id);
        decoder->timer_id = 0;
    }
    g_clear_pointer(&decoder->cur_frame, spice_frame_free);
    g_queue_foreach(decoder->msgq, (GFunc)spice_frame_free, NULL);
    g_queue_clear(decoder->msgq);
}

static gboolean vtb_decoder_queue_frame(VideoDecoder *video_decoder,
                                         SpiceFrame *frame, int margin)
{
    VtbDecoder *decoder = (VtbDecoder *)video_decoder;

    SpiceFrame *last = g_queue_peek_tail(decoder->msgq);
    if (last && spice_mmtime_diff(frame->mm_time, last->mm_time) < 0) {
        SPICE_DEBUG("VTB: stream time went backwards, resetting queue");
        vtb_decoder_drop_queue(decoder);
    }

    /* Drop late frames early to avoid unnecessary decode work */
    if (margin < 0) {
        SPICE_DEBUG("VTB: dropping late frame (margin %d ms)", margin);
        spice_frame_free(frame);
        return TRUE;
    }

    g_queue_push_tail(decoder->msgq, frame);
    vtb_decoder_schedule(decoder);
    return TRUE;
}

static void vtb_decoder_reschedule(VideoDecoder *video_decoder)
{
    VtbDecoder *decoder = (VtbDecoder *)video_decoder;

    if (decoder->timer_id) {
        g_source_remove(decoder->timer_id);
        decoder->timer_id = 0;
    }
    vtb_decoder_schedule(decoder);
}

static void vtb_decoder_destroy(VideoDecoder *video_decoder)
{
    VtbDecoder *decoder = (VtbDecoder *)video_decoder;

    vtb_decoder_drop_queue(decoder);
    g_queue_free(decoder->msgq);

    if (decoder->session) {
        VTDecompressionSessionInvalidate(decoder->session);
        CFRelease(decoder->session);
    }
    if (decoder->fmt_desc) {
        CFRelease(decoder->fmt_desc);
    }

    if (decoder->decoded_pixbuf) {
        CVPixelBufferRelease(decoder->decoded_pixbuf);
        decoder->decoded_pixbuf = NULL;
    }

    g_free(decoder->sps);
    g_free(decoder->pps);
    g_free(decoder->vps);
    g_free(decoder->out_frame);
    g_free(decoder);
}

/* ============================================================
 * Public API
 * ============================================================ */

G_GNUC_INTERNAL
gboolean gstvideo_has_codec(int codec_type)
{
    switch (codec_type) {
    case SPICE_VIDEO_CODEC_TYPE_H264: return TRUE;
    case SPICE_VIDEO_CODEC_TYPE_H265: return TRUE;
    default:                          return FALSE;
    }
}

G_GNUC_INTERNAL
VideoDecoder *create_gstreamer_decoder(int codec_type, display_stream *stream)
{
    if (!gstvideo_has_codec(codec_type)) return NULL;

    VtbDecoder *decoder = g_new0(VtbDecoder, 1);
    decoder->base.destroy      = vtb_decoder_destroy;
    decoder->base.reschedule   = vtb_decoder_reschedule;
    decoder->base.queue_frame  = vtb_decoder_queue_frame;
    decoder->base.codec_type   = codec_type;
    decoder->base.stream       = stream;
    decoder->msgq              = g_queue_new();

    SPICE_DEBUG("VTB: created %s decoder",
                codec_type == SPICE_VIDEO_CODEC_TYPE_H264 ? "H.264" : "H.265");
    return (VideoDecoder *)decoder;
}

#endif /* __APPLE__ */
