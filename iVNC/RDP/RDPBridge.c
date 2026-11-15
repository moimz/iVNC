#include "RDPBridge.h"

#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/channels/channels.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/error.h>
#include <freerdp/graphics.h>
#include <freerdp/codec/color.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <winpr/user.h>
#include <pthread.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/cliprdr.h>

const char *ivnc_freerdp_version(void) {
    return freerdp_get_version_string();
}

// MARK: FreeRDP 로그 → 앱 로그

static void (*log_sink)(const char *line);

static BOOL log_message(const wLogMessage *msg) {
    if (!log_sink || !msg || !msg->TextString) return TRUE;
    // 빌드 옵션 안내(시작할 때마다 나옴)는 뺀다
    if (msg->FunctionName && strncmp(msg->FunctionName, "log_build", 9) == 0) return TRUE;
    char buf[768];
    snprintf(buf, sizeof buf, "%s %s: %s", msg->Level >= WLOG_ERROR ? "오류" : "경고",
             msg->FunctionName ? msg->FunctionName : "", msg->TextString);
    log_sink(buf);
    return TRUE;
}

void ivnc_rdp_set_log(void (*sink)(const char *line)) {
    log_sink = sink;
    wLog *root = WLog_GetRoot();
    if (!root) return;
    if (!WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK)) return;
    wLogAppender *appender = WLog_GetLogAppender(root);
    static wLogCallbacks callbacks;
    callbacks.message = log_message;
    if (appender) (void)WLog_ConfigureAppender(appender, "callbacks", &callbacks);
    (void)WLog_SetLogLevel(root, WLOG_WARN);
}

struct ivnc_rdp {
    ivnc_rdp_callbacks cb;
    rdpContext *context;
    /// 접속을 마쳐 입력을 보내도 되는지
    atomic_int ready;
    /// 우리가 끊으라고 했는지
    atomic_int stopping;
    char username[256], domain[256], password[256];
    char config_path[1024];

    // 클립보드 (cliprdr). clip_lock 이 아래 전부를 지킨다
    int clip_enabled;
    pthread_mutex_t clip_lock;
    CliprdrClientContext *clip;
    /// 이 기기에서 복사한 것
    uint8_t *local_text, *local_dib, *local_png;
    size_t local_text_len, local_dib_len, local_png_len;
    /// 원격 PNG 형식 번호 (0 = 없음), 지금 요청한 형식
    UINT32 remote_png_id;
    UINT32 requested;
};

/// 우리가 원격에 알리는 PNG 형식 번호 (이름 "PNG", 0xC000 이상 아무 번호)
#define IVNC_PNG_FORMAT 0xC0F0

/// FreeRDP 문맥에 우리 것을 붙인다 (rdpClientContext 가 맨 앞이어야 한다)
typedef struct {
    rdpClientContext common;
    ivnc_rdp *owner;
} ivnc_context;

static ivnc_rdp *owner_of(rdpContext *context) {
    return context ? ((ivnc_context *)context)->owner : NULL;
}

static void say(ivnc_rdp *r, const char *fmt, ...) {
    if (!r || !r->cb.log) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    r->cb.log(r->cb.owner, buf);
}

// MARK: 그림

static BOOL begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd && gdi->primary->hdc->hwnd->invalid)
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

/// 한 장을 다 그렸다: 바뀐 영역만 Swift 로
static BOOL end_paint(rdpContext *context) {
    ivnc_rdp *r = owner_of(context);
    rdpGdi *gdi = context->gdi;
    if (!r || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) return TRUE;
    HGDI_RGN inv = gdi->primary->hdc->hwnd->invalid;
    if (!inv || inv->null) return TRUE;
    int x = inv->x, y = inv->y, w = inv->w, h = inv->h;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > (int)gdi->width) w = (int)gdi->width - x;
    if (y + h > (int)gdi->height) h = (int)gdi->height - y;
    if (w <= 0 || h <= 0) return TRUE;
    if (r->cb.paint)
        r->cb.paint(r->cb.owner, gdi->primary_buffer, (int)gdi->stride, (int)gdi->width, (int)gdi->height, x, y, w, h);
    return TRUE;
}

static BOOL desktop_resize(rdpContext *context) {
    ivnc_rdp *r = owner_of(context);
    rdpSettings *s = context->settings;
    UINT32 w = freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, w, h)) return FALSE;
    say(r, "원격 화면 크기 바뀜 %ux%u", w, h);
    if (r && r->cb.resized) r->cb.resized(r->cb.owner, (int)w, (int)h);
    return TRUE;
}

static BOOL play_sound(rdpContext *context, const PLAY_SOUND_UPDATE *s) { (void)context; (void)s; return TRUE; }
static BOOL set_indicators(rdpContext *context, UINT16 flags) { (void)context; (void)flags; return TRUE; }
static BOOL set_ime_status(rdpContext *context, UINT16 id, UINT32 state, UINT32 mode) {
    ivnc_rdp *r = owner_of(context);
    say(r, "원격 입력기 상태 id=%u state=%u mode=0x%x", id, state, mode);
    // IME_CMODE_NATIVE(1) = 한글
    if (r && r->cb.ime && state) r->cb.ime(r->cb.owner, (mode & 1) ? 1 : 0);
    return TRUE;
}

// MARK: 커서 (원격 커서 모양 → 이 기기 커서)

typedef struct {
    rdpPointer pointer;
    void *handle;
} ivnc_pointer;

static BOOL pointer_new(rdpContext *context, rdpPointer *pointer) {
    ivnc_rdp *r = owner_of(context);
    ivnc_pointer *p = (ivnc_pointer *)pointer;
    p->handle = NULL;
    if (!r || !r->cb.cursor_new || pointer->width == 0 || pointer->height == 0) return TRUE;
    size_t stride = (size_t)pointer->width * 4;
    BYTE *data = calloc(1, stride * pointer->height);
    if (!data) return FALSE;
    if (freerdp_image_copy_from_pointer_data(data, PIXEL_FORMAT_BGRA32, (UINT32)stride, 0, 0, pointer->width, pointer->height,
                                             pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData,
                                             pointer->lengthAndMask, pointer->xorBpp, context->gdi ? &context->gdi->palette : NULL))
        p->handle = r->cb.cursor_new(r->cb.owner, data, (int)pointer->width, (int)pointer->height, (int)pointer->xPos, (int)pointer->yPos);
    free(data);
    return TRUE;
}

static void pointer_free(rdpContext *context, rdpPointer *pointer) {
    ivnc_rdp *r = owner_of(context);
    ivnc_pointer *p = (ivnc_pointer *)pointer;
    if (r && r->cb.cursor_free && p->handle) r->cb.cursor_free(r->cb.owner, p->handle);
    p->handle = NULL;
}

static BOOL pointer_set(rdpContext *context, rdpPointer *pointer) {
    ivnc_rdp *r = owner_of(context);
    ivnc_pointer *p = (ivnc_pointer *)pointer;
    if (r && r->cb.cursor_set) r->cb.cursor_set(r->cb.owner, p->handle, p->handle ? 0 : 2);
    return TRUE;
}

static BOOL pointer_set_null(rdpContext *context) {
    ivnc_rdp *r = owner_of(context);
    if (r && r->cb.cursor_set) r->cb.cursor_set(r->cb.owner, NULL, 1);
    return TRUE;
}

static BOOL pointer_set_default(rdpContext *context) {
    ivnc_rdp *r = owner_of(context);
    if (r && r->cb.cursor_set) r->cb.cursor_set(r->cb.owner, NULL, 2);
    return TRUE;
}

static BOOL pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) { (void)context; (void)x; (void)y; return TRUE; }

// MARK: 클립보드 (cliprdr 채널)

static ivnc_rdp *clip_owner(CliprdrClientContext *clip) { return clip ? (ivnc_rdp *)clip->custom : NULL; }

/// 가진 것을 원격에 알린다 (clip_lock 잡은 채로)
static UINT clip_send_format_list(ivnc_rdp *r) {
    if (!r->clip) return CHANNEL_RC_OK;
    CLIPRDR_FORMAT formats[3];
    memset(formats, 0, sizeof formats);
    UINT32 n = 0;
    if (r->local_text) formats[n++].formatId = CF_UNICODETEXT;
    if (r->local_dib) formats[n++].formatId = CF_DIB;
    if (r->local_png) { formats[n].formatId = IVNC_PNG_FORMAT; formats[n].formatName = "PNG"; n++; }
    CLIPRDR_FORMAT_LIST list;
    memset(&list, 0, sizeof list);
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = n;
    list.formats = formats;
    return r->clip->ClientFormatList(r->clip, &list);
}

static UINT clip_monitor_ready(CliprdrClientContext *clip, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    ivnc_rdp *r = clip_owner(clip);
    if (!r) return CHANNEL_RC_OK;
    CLIPRDR_GENERAL_CAPABILITY_SET general;
    memset(&general, 0, sizeof general);
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps;
    memset(&caps, 0, sizeof caps);
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT rc = clip->ClientCapabilities(clip, &caps);
    if (rc != CHANNEL_RC_OK) return rc;
    pthread_mutex_lock(&r->clip_lock);
    rc = clip_send_format_list(r);
    pthread_mutex_unlock(&r->clip_lock);
    say(r, "클립보드 채널 준비됨");
    return rc;
}

static UINT clip_server_capabilities(CliprdrClientContext *clip, const CLIPRDR_CAPABILITIES *caps) {
    (void)clip; (void)caps;
    return CHANNEL_RC_OK;
}

/// 원격에서 복사함: 받았다고 답하고, 글자 → PNG → DIB 순으로 하나를 바로 가져온다
static UINT clip_server_format_list(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST *list) {
    ivnc_rdp *r = clip_owner(clip);
    BOOL text = FALSE, dib = FALSE;
    UINT32 png = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        const CLIPRDR_FORMAT *f = &list->formats[i];
        if (f->formatId == CF_UNICODETEXT) text = TRUE;
        else if (f->formatId == CF_DIB) dib = TRUE;
        else if (f->formatName && strcmp(f->formatName, "PNG") == 0) png = f->formatId;
    }
    CLIPRDR_FORMAT_LIST_RESPONSE response;
    memset(&response, 0, sizeof response);
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = clip->ClientFormatListResponse(clip, &response);
    if (rc != CHANNEL_RC_OK || !r) return rc;
    UINT32 want = text ? CF_UNICODETEXT : png ? png : dib ? CF_DIB : 0;
    say(r, "원격 복사: 형식 %u개 (글자 %s, PNG %s, DIB %s)", list->numFormats, text ? "있음" : "없음", png ? "있음" : "없음", dib ? "있음" : "없음");
    if (!want) return CHANNEL_RC_OK;
    pthread_mutex_lock(&r->clip_lock);
    r->remote_png_id = png;
    r->requested = want;
    pthread_mutex_unlock(&r->clip_lock);
    CLIPRDR_FORMAT_DATA_REQUEST request;
    memset(&request, 0, sizeof request);
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = want;
    return clip->ClientFormatDataRequest(clip, &request);
}

static UINT clip_server_format_list_response(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)clip; (void)response;
    return CHANNEL_RC_OK;
}

/// 원격에서 붙여넣음: 이 기기에서 복사한 것을 보낸다
static UINT clip_server_format_data_request(CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    ivnc_rdp *r = clip_owner(clip);
    CLIPRDR_FORMAT_DATA_RESPONSE response;
    memset(&response, 0, sizeof response);
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (!r) {
        response.common.msgFlags = CB_RESPONSE_FAIL;
        return clip->ClientFormatDataResponse(clip, &response);
    }
    pthread_mutex_lock(&r->clip_lock);
    const uint8_t *data = NULL;
    size_t len = 0;
    switch (request->requestedFormatId) {
    case CF_UNICODETEXT: data = r->local_text; len = r->local_text_len; break;
    case CF_DIB: data = r->local_dib; len = r->local_dib_len; break;
    case IVNC_PNG_FORMAT: data = r->local_png; len = r->local_png_len; break;
    default: break;
    }
    response.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.common.dataLen = data ? (UINT32)len : 0;
    response.requestedFormatData = data;
    UINT rc = clip->ClientFormatDataResponse(clip, &response);
    pthread_mutex_unlock(&r->clip_lock);
    say(r, "원격이 붙여넣음: 형식 0x%x, %zu바이트%s", request->requestedFormatId, len, data ? "" : " (없음)");
    return rc;
}

/// 원격에서 복사한 내용이 옴
static UINT clip_server_format_data_response(CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    ivnc_rdp *r = clip_owner(clip);
    if (!r) return CHANNEL_RC_OK;
    pthread_mutex_lock(&r->clip_lock);
    UINT32 format = r->requested;
    UINT32 png = r->remote_png_id;
    r->requested = 0;
    pthread_mutex_unlock(&r->clip_lock);
    if ((response->common.msgFlags & CB_RESPONSE_FAIL) || !response->requestedFormatData || response->common.dataLen == 0) {
        say(r, "원격 복사 내용 못 받음 (형식 0x%x)", format);
        return CHANNEL_RC_OK;
    }
    int kind = format == CF_UNICODETEXT ? 1 : (png && format == png) ? 2 : format == CF_DIB ? 3 : 0;
    if (kind && r->cb.clip_remote)
        r->cb.clip_remote(r->cb.owner, kind, response->requestedFormatData, (int)response->common.dataLen);
    return CHANNEL_RC_OK;
}

static UINT clip_ok_lock(CliprdrClientContext *clip, const CLIPRDR_LOCK_CLIPBOARD_DATA *l) { (void)clip; (void)l; return CHANNEL_RC_OK; }
static UINT clip_ok_unlock(CliprdrClientContext *clip, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *l) { (void)clip; (void)l; return CHANNEL_RC_OK; }
static UINT clip_file_request(CliprdrClientContext *clip, const CLIPRDR_FILE_CONTENTS_REQUEST *req) {
    // 파일은 알리지 않으니 올 일이 없다: 실패로 답한다
    CLIPRDR_FILE_CONTENTS_RESPONSE response;
    memset(&response, 0, sizeof response);
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    response.streamId = req->streamId;
    return clip->ClientFileContentsResponse(clip, &response);
}

static void channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    rdpContext *ctx = (rdpContext *)context;
    ivnc_rdp *r = owner_of(ctx);
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *clip = (CliprdrClientContext *)e->pInterface;
        if (!r || !clip) return;
        clip->custom = r;
        clip->MonitorReady = clip_monitor_ready;
        clip->ServerCapabilities = clip_server_capabilities;
        clip->ServerFormatList = clip_server_format_list;
        clip->ServerFormatListResponse = clip_server_format_list_response;
        clip->ServerFormatDataRequest = clip_server_format_data_request;
        clip->ServerFormatDataResponse = clip_server_format_data_response;
        clip->ServerLockClipboardData = clip_ok_lock;
        clip->ServerUnlockClipboardData = clip_ok_unlock;
        clip->ServerFileContentsRequest = clip_file_request;
        pthread_mutex_lock(&r->clip_lock);
        r->clip = clip;
        pthread_mutex_unlock(&r->clip_lock);
    } else {
        freerdp_client_OnChannelConnectedEventHandler(context, e);
    }
}

static void channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    ivnc_rdp *r = owner_of((rdpContext *)context);
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        if (!r) return;
        pthread_mutex_lock(&r->clip_lock);
        if (r->clip) r->clip->custom = NULL;
        r->clip = NULL;
        pthread_mutex_unlock(&r->clip_lock);
    } else {
        freerdp_client_OnChannelDisconnectedEventHandler(context, e);
    }
}

static uint8_t *dup_bytes(const uint8_t *p, int len) {
    if (!p || len <= 0) return NULL;
    uint8_t *d = malloc((size_t)len);
    if (d) memcpy(d, p, (size_t)len);
    return d;
}

void ivnc_rdp_set_clipboard(ivnc_rdp *r, int enabled) { if (r) r->clip_enabled = enabled; }

void ivnc_rdp_set_config_path(ivnc_rdp *r, const char *path) {
    if (r) snprintf(r->config_path, sizeof r->config_path, "%s", path ? path : "");
}

void ivnc_rdp_clip_set(ivnc_rdp *r, const uint8_t *text, int textLength, const uint8_t *dib, int dibLength,
                       const uint8_t *png, int pngLength) {
    if (!r) return;
    pthread_mutex_lock(&r->clip_lock);
    free(r->local_text); free(r->local_dib); free(r->local_png);
    r->local_text = dup_bytes(text, textLength); r->local_text_len = r->local_text ? (size_t)textLength : 0;
    r->local_dib = dup_bytes(dib, dibLength); r->local_dib_len = r->local_dib ? (size_t)dibLength : 0;
    r->local_png = dup_bytes(png, pngLength); r->local_png_len = r->local_png ? (size_t)pngLength : 0;
    if (r->clip) clip_send_format_list(r);
    pthread_mutex_unlock(&r->clip_lock);
}

// MARK: 접속 단계

static BOOL pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *s = context->settings;
    if (!freerdp_settings_set_uint32(s, FreeRDP_OsMajorType, OSMAJORTYPE_IOS)) return FALSE;
    // 채널이 붙고 떨어질 때: 클립보드는 우리가, 나머지(그래픽 파이프라인 등)는 FreeRDP 공용 처리에 (GFX → gdi)
    PubSub_SubscribeChannelConnected(context->pubSub, channel_connected);
    PubSub_SubscribeChannelDisconnected(context->pubSub, channel_disconnected);
    return TRUE;
}

static BOOL post_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    ivnc_rdp *r = owner_of(context);
    // 메모리 순서 B G R X (우리 Framebuffer 와 같다)
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;
    rdpPointer pointer;
    memset(&pointer, 0, sizeof pointer);
    pointer.size = sizeof(ivnc_pointer);
    pointer.New = pointer_new;
    pointer.Free = pointer_free;
    pointer.Set = pointer_set;
    pointer.SetNull = pointer_set_null;
    pointer.SetDefault = pointer_set_default;
    pointer.SetPosition = pointer_set_position;
    graphics_register_pointer(context->graphics, &pointer);
    context->update->BeginPaint = begin_paint;
    context->update->EndPaint = end_paint;
    context->update->DesktopResize = desktop_resize;
    context->update->PlaySound = play_sound;
    context->update->SetKeyboardIndicators = set_indicators;
    context->update->SetKeyboardImeStatus = set_ime_status;
    rdpSettings *s = context->settings;
    UINT32 w = freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
    say(r, "접속됨 %ux%u, 그래픽 파이프라인 %s, H.264 %s", w, h,
        freerdp_settings_get_bool(s, FreeRDP_SupportGraphicsPipeline) ? "켬" : "끔",
        freerdp_settings_get_bool(s, FreeRDP_GfxH264) ? "켬" : "끔");
    atomic_store(&r->ready, 1);
    if (r->cb.resized) r->cb.resized(r->cb.owner, (int)w, (int)h);
    return TRUE;
}

static void post_disconnect(freerdp *instance) {
    if (!instance || !instance->context) return;
    ivnc_rdp *r = owner_of(instance->context);
    if (r) atomic_store(&r->ready, 0);
    PubSub_UnsubscribeChannelConnected(instance->context->pubSub, channel_connected);
    PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, channel_disconnected);
    gdi_free(instance);
}

/// 계정·암호는 접속 전에 설정에 넣어 두었다. 비었으면 물어볼 곳이 없으니 실패
static BOOL authenticate(freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
    (void)reason;
    ivnc_rdp *r = owner_of(instance->context);
    if (!r || !r->username[0] || !r->password[0]) return FALSE;
    if (!*username) *username = strdup(r->username);
    if (!*password) *password = strdup(r->password);
    if (!*domain && r->domain[0]) *domain = strdup(r->domain);
    return TRUE;
}

/// 처음 보는 원격 인증서: 집 안 윈도우 PC 는 대개 스스로 만든 인증서라 받아들이고 기억한다 (다음부터 바뀌면 묻는다)
static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    (void)subject; (void)issuer; (void)flags;
    say(owner_of(instance->context), "처음 보는 인증서 기억 %s:%u (%s) 지문 %s", host, port, common_name ? common_name : "", fingerprint ? fingerprint : "");
    return 1; // 받아들이고 기억
}

static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                        const char *subject, const char *issuer, const char *fingerprint,
                                        const char *old_subject, const char *old_issuer, const char *old_fingerprint, DWORD flags) {
    (void)subject; (void)issuer; (void)old_subject; (void)old_issuer; (void)flags;
    ivnc_rdp *r = owner_of(instance->context);
    say(r, "인증서 바뀜 %s:%u (%s) %s → %s", host, port, common_name ? common_name : "",
        old_fingerprint ? old_fingerprint : "", fingerprint ? fingerprint : "");
    if (!r || !r->cb.certificate_changed) return 0;
    int ok = r->cb.certificate_changed(r->cb.owner, host, port, old_fingerprint ? old_fingerprint : "", fingerprint ? fingerprint : "");
    say(r, "바뀐 인증서: %s", ok ? "사용자가 받아들임" : "사용자가 거절");
    return ok ? 1 : 0;
}

static int logon_error_info(freerdp *instance, UINT32 data, UINT32 type) {
    say(owner_of(instance->context), "로그온 알림 %s [%s]", freerdp_get_logon_error_info_data(data), freerdp_get_logon_error_info_type(type));
    return 1;
}

static BOOL client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->AuthenticateEx = authenticate;
    instance->VerifyCertificateEx = verify_certificate;
    instance->VerifyChangedCertificateEx = verify_changed_certificate;
    instance->LogonErrorInfo = logon_error_info;
    return TRUE;
}

static void client_free(freerdp *instance, rdpContext *context) { (void)instance; (void)context; }
static int client_start(rdpContext *context) { (void)context; return 0; }
static int client_stop(rdpContext *context) { (void)context; return 0; }

// MARK: 바깥 함수

ivnc_rdp *ivnc_rdp_new(ivnc_rdp_callbacks callbacks) {
    RDP_CLIENT_ENTRY_POINTS ep;
    memset(&ep, 0, sizeof ep);
    ep.Version = RDP_CLIENT_INTERFACE_VERSION;
    ep.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    ep.ContextSize = sizeof(ivnc_context);
    ep.ClientNew = client_new;
    ep.ClientFree = client_free;
    ep.ClientStart = client_start;
    ep.ClientStop = client_stop;
    rdpContext *context = freerdp_client_context_new(&ep);
    if (!context) return NULL;
    ivnc_rdp *r = calloc(1, sizeof *r);
    r->cb = callbacks;
    r->context = context;
    pthread_mutex_init(&r->clip_lock, NULL);
    ((ivnc_context *)context)->owner = r;
    return r;
}

static int classify(UINT32 e) {
    switch (e) {
    case FREERDP_ERROR_SUCCESS: return IVNC_RDP_OK;
    case FREERDP_ERROR_AUTHENTICATION_FAILED:
    case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
    case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
    case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
        return IVNC_RDP_AUTH;
    case FREERDP_ERROR_DNS_ERROR:
    case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
        return IVNC_RDP_DNS;
    case FREERDP_ERROR_CONNECT_FAILED:
    case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
        return IVNC_RDP_UNREACHABLE;
    case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
    case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
    case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
    case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
    case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
        return IVNC_RDP_ACCOUNT;
    case FREERDP_ERROR_INSUFFICIENT_PRIVILEGES:
    case FREERDP_ERROR_SERVER_DENIED_CONNECTION:
        return IVNC_RDP_DENIED;
    case FREERDP_ERROR_RPC_INITIATED_DISCONNECT:
    case FREERDP_ERROR_RPC_INITIATED_DISCONNECT_BY_USER:
    case FREERDP_ERROR_LOGOFF_BY_USER:
        return IVNC_RDP_LOGOFF;
    case FREERDP_ERROR_DISCONNECTED_BY_OTHER_CONNECTION:
        return IVNC_RDP_OTHER_SESSION;
    case FREERDP_ERROR_TLS_CONNECT_FAILED:
    case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED:
        return IVNC_RDP_SECURITY;
    default: return IVNC_RDP_OTHER;
    }
}

int ivnc_rdp_run(ivnc_rdp *r, const char *host, int port, const char *username, const char *domain,
                 const char *password, int width, int height, char *message, int len) {
    if (message && len > 0) message[0] = 0;
    rdpContext *context = r->context;
    freerdp *instance = context->instance;
    rdpSettings *s = context->settings;
    snprintf(r->username, sizeof r->username, "%s", username ? username : "");
    snprintf(r->domain, sizeof r->domain, "%s", domain ? domain : "");
    snprintf(r->password, sizeof r->password, "%s", password ? password : "");

    BOOL ok = (!r->config_path[0] || freerdp_settings_set_string(s, FreeRDP_ConfigPath, r->config_path))
        && freerdp_settings_set_string(s, FreeRDP_ServerHostname, host)
        && freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)port)
        && freerdp_settings_set_string(s, FreeRDP_Username, r->username)
        && freerdp_settings_set_string(s, FreeRDP_Password, r->password)
        && (!r->domain[0] || freerdp_settings_set_string(s, FreeRDP_Domain, r->domain))
        && freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)width)
        && freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)height)
        && freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32)
        // 그래픽 파이프라인 + H.264 (VideoToolbox 로 푼다)
        && freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE)
        && freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE)
        && freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, FALSE)
        && freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, FALSE)
        && freerdp_settings_set_bool(s, FreeRDP_NetworkAutoDetect, TRUE)
        && freerdp_set_connection_type(s, CONNECTION_TYPE_AUTODETECT)
        // 원격 화면 크기를 접속 중에 바꿀 수 있게 (나중 창 크기 맞춤)
        && freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE)
        && freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, FALSE)
        // 아직 안 쓰는 것: 소리·드라이브. 클립보드는 켰을 때만
        && freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE)
        && freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, r->clip_enabled ? TRUE : FALSE)
        && freerdp_settings_set_bool(s, FreeRDP_AutoReconnectionEnabled, FALSE)
        // 한국어 자판 (키 자리는 미국 자판과 같다). 103/106 키 한국 자판이라야 스캔코드 0x72 가 한/영 키
        && freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, 0x00000412)
        && freerdp_settings_set_uint32(s, FreeRDP_KeyboardType, 8)
        && freerdp_settings_set_uint32(s, FreeRDP_KeyboardSubType, 3)
        && freerdp_settings_set_uint32(s, FreeRDP_KeyboardFunctionKey, 12);
    if (!ok) {
        if (message) snprintf(message, (size_t)len, "설정 실패");
        return IVNC_RDP_OTHER;
    }

    say(r, "접속 시작 %s:%d 계정 %s%s%s, 화면 %dx%d", host, port, r->domain, r->domain[0] ? "\\" : "", r->username, width, height);
    BOOL connected = freerdp_connect(instance);
    if (connected) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        while (!freerdp_shall_disconnect_context(context)) {
            DWORD n = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
            if (n == 0) { say(r, "이벤트 핸들 없음"); break; }
            if (WaitForMultipleObjects(n, handles, FALSE, INFINITE) == WAIT_FAILED) { say(r, "기다리기 실패"); break; }
            if (!freerdp_check_event_handles(context)) {
                if (freerdp_get_last_error(context) == FREERDP_ERROR_SUCCESS) say(r, "이벤트 처리 실패");
                break;
            }
        }
    }
    UINT32 err = freerdp_get_last_error(context);
    UINT32 info = freerdp_error_info(instance);
    // 끊긴 이유가 서버가 보낸 오류 정보(로그아웃 등)면 그쪽으로
    if ((err == FREERDP_ERROR_SUCCESS || !connected) && info != 0 && classify(MAKE_FREERDP_ERROR(ERRINFO, info)) != IVNC_RDP_OTHER)
        err = MAKE_FREERDP_ERROR(ERRINFO, info);
    say(r, "접속 끝: %s (0x%08x, 오류 정보 0x%x)", freerdp_get_last_error_string(err), err, info);
    if (message) snprintf(message, (size_t)len, "%s", freerdp_get_last_error_string(err));
    freerdp_disconnect(instance);
    memset(r->password, 0, sizeof r->password);
    if (atomic_load(&r->stopping)) return IVNC_RDP_OK;
    if (err == FREERDP_ERROR_SUCCESS && connected) return IVNC_RDP_LOGOFF; // 원격이 끊음
    return err == FREERDP_ERROR_SUCCESS ? IVNC_RDP_OTHER : classify(err);
}

void ivnc_rdp_stop(ivnc_rdp *r) {
    if (!r) return;
    atomic_store(&r->stopping, 1);
    freerdp_abort_connect_context(r->context);
}

void ivnc_rdp_free(ivnc_rdp *r) {
    if (!r) return;
    freerdp_client_context_free(r->context);
    free(r->local_text); free(r->local_dib); free(r->local_png);
    pthread_mutex_destroy(&r->clip_lock);
    memset(r, 0, sizeof *r);
    free(r);
}

void ivnc_rdp_mouse(ivnc_rdp *r, uint16_t flags, int x, int y) {
    if (!r || !atomic_load(&r->ready)) return;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    freerdp_input_send_mouse_event(r->context->input, flags, (UINT16)x, (UINT16)y);
}

void ivnc_rdp_key(ivnc_rdp *r, int down, uint32_t scancode) {
    if (!r || !atomic_load(&r->ready)) return;
    freerdp_input_send_keyboard_event_ex(r->context->input, down ? TRUE : FALSE, FALSE, scancode);
}

void ivnc_rdp_unicode(ivnc_rdp *r, int down, uint16_t code) {
    if (!r || !atomic_load(&r->ready)) return;
    freerdp_input_send_unicode_keyboard_event(r->context->input, down ? 0 : KBD_FLAGS_RELEASE, code);
}

void ivnc_rdp_suppress_output(ivnc_rdp *r, int suppress) {
    if (!r || !atomic_load(&r->ready)) return;
    rdpSettings *s = r->context->settings;
    RECTANGLE_16 area = { 0, 0, (UINT16)freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
                          (UINT16)freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight) };
    r->context->update->SuppressOutput(r->context, suppress ? 0 : 1, suppress ? NULL : &area);
}

uint64_t ivnc_rdp_received(ivnc_rdp *r) {
    if (!r || !atomic_load(&r->ready)) return 0;
    UINT64 in = 0, out = 0, inp = 0, outp = 0;
    if (!freerdp_get_stats(r->context->rdp, &in, &out, &inp, &outp)) return 0;
    return in;
}
