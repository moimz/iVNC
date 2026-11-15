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
#include <winpr/synch.h>
#include <winpr/wlog.h>

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
};

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
    say(owner_of(context), "원격 입력기 상태 id=%u state=%u mode=0x%x", id, state, mode);
    return TRUE;
}

// MARK: 접속 단계

static BOOL pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *s = context->settings;
    if (!freerdp_settings_set_uint32(s, FreeRDP_OsMajorType, OSMAJORTYPE_IOS)) return FALSE;
    // 채널(그래픽 파이프라인 등)이 붙고 떨어질 때 FreeRDP 공용 처리에 맡긴다 (GFX → gdi)
    PubSub_SubscribeChannelConnected(context->pubSub, freerdp_client_OnChannelConnectedEventHandler);
    PubSub_SubscribeChannelDisconnected(context->pubSub, freerdp_client_OnChannelDisconnectedEventHandler);
    return TRUE;
}

static BOOL post_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    ivnc_rdp *r = owner_of(context);
    // 메모리 순서 B G R X (우리 Framebuffer 와 같다)
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;
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
    PubSub_UnsubscribeChannelConnected(instance->context->pubSub, freerdp_client_OnChannelConnectedEventHandler);
    PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, freerdp_client_OnChannelDisconnectedEventHandler);
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

/// 원격 인증서: 집 안 윈도우 PC 는 대개 스스로 만든 인증서라 받아들인다 (지문은 로그에)
static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    (void)subject; (void)issuer; (void)flags;
    say(owner_of(instance->context), "인증서 받아들임 %s:%u (%s) 지문 %s", host, port, common_name ? common_name : "", fingerprint ? fingerprint : "");
    return 2; // 이번 접속만
}

static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                        const char *subject, const char *issuer, const char *fingerprint,
                                        const char *old_subject, const char *old_issuer, const char *old_fingerprint, DWORD flags) {
    (void)subject; (void)issuer; (void)old_subject; (void)old_issuer; (void)flags;
    say(owner_of(instance->context), "인증서 바뀜 %s:%u (%s) %s → %s", host, port, common_name ? common_name : "",
        old_fingerprint ? old_fingerprint : "", fingerprint ? fingerprint : "");
    return 2;
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

    BOOL ok = freerdp_settings_set_string(s, FreeRDP_ServerHostname, host)
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
        // 아직 안 쓰는 것: 소리·클립보드·드라이브
        && freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE)
        && freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, FALSE)
        && freerdp_settings_set_bool(s, FreeRDP_AutoReconnectionEnabled, FALSE)
        // 한국어 자판 (키 자리는 미국 자판과 같다)
        && freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, 0x00000412);
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
