// FreeRDP 를 Swift 에서 쓰기 위한 얇은 C 다리. Swift 는 FreeRDP 헤더(매크로·구조체)를 직접 보지 않고 이 함수들만 본다.
#ifndef RDPBridge_h
#define RDPBridge_h

#include <stdint.h>

/// 링크 확인용: FreeRDP 버전 문자열 (예: "3.33.1")
const char *ivnc_freerdp_version(void);

typedef struct ivnc_rdp ivnc_rdp;

/// FreeRDP 자체 경고·오류 로그를 받을 함수 (한 번만, 접속 전에)
void ivnc_rdp_set_log(void (*sink)(const char *line));

/// 접속 한 번의 알림. 모두 접속 스레드(ivnc_rdp_run 을 부른 스레드)에서 불린다
typedef struct {
    void *owner;
    /// 화면 그림이 바뀜. buffer 는 원격 화면 전체 (메모리 순서 B G R X, 줄 간격 stride). 이 함수 안에서만 읽는다
    void (*paint)(void *owner, const uint8_t *buffer, int stride, int width, int height, int x, int y, int w, int h);
    /// 접속 완료 또는 원격 화면 크기가 바뀜
    void (*resized)(void *owner, int width, int height);
    /// 진행 상황·로그 한 줄 (UTF-8)
    void (*log)(void *owner, const char *message);
} ivnc_rdp_callbacks;

/// 실패 종류 (Swift 가 한국어 문구로 바꾼다)
enum {
    IVNC_RDP_OK = 0,             // 정상으로 끝남 (우리가 끊음)
    IVNC_RDP_AUTH = 1,           // 계정·암호가 틀림
    IVNC_RDP_DNS = 2,            // 주소를 못 찾음
    IVNC_RDP_UNREACHABLE = 3,    // 접속 못 함 (꺼짐, 원격 데스크톱 꺼짐, 방화벽)
    IVNC_RDP_ACCOUNT = 4,        // 계정 잠김·막힘·암호 만료
    IVNC_RDP_DENIED = 5,         // 권한 없음 (원격 데스크톱 사용자가 아님)
    IVNC_RDP_LOGOFF = 6,         // 원격에서 로그아웃·연결 끊기
    IVNC_RDP_OTHER_SESSION = 7,  // 다른 곳에서 접속해 끊김
    IVNC_RDP_SECURITY = 8,       // 보안 협상 실패 (NLA·TLS)
    IVNC_RDP_OTHER = 99,
};

ivnc_rdp *ivnc_rdp_new(ivnc_rdp_callbacks callbacks);
/// 접속하고 끊길 때까지 돌린다 (막힘). 돌려주는 값: 위 실패 종류. message 에 FreeRDP 원문 (최대 len)
int ivnc_rdp_run(ivnc_rdp *r, const char *host, int port, const char *username, const char *domain,
                 const char *password, int width, int height, char *message, int len);
/// 다른 스레드에서: 끊으라고 알린다 (run 이 곧 돌아온다)
void ivnc_rdp_stop(ivnc_rdp *r);
/// run 이 돌아온 뒤에 지운다
void ivnc_rdp_free(ivnc_rdp *r);

/// 마우스 (FreeRDP PTR_FLAGS_*). 접속 전이면 무시
void ivnc_rdp_mouse(ivnc_rdp *r, uint16_t flags, int x, int y);
/// 키 (스캔코드, 확장 키는 0x100 을 더함)
void ivnc_rdp_key(ivnc_rdp *r, int down, uint32_t scancode);
/// 글자 하나 (UTF-16 코드 단위)
void ivnc_rdp_unicode(ivnc_rdp *r, int down, uint16_t code);
/// 화면 받기 멈춤(1)·다시(0) — 원격이 그림을 보내지 않게 한다
void ivnc_rdp_suppress_output(ivnc_rdp *r, int suppress);
/// 지금까지 받은 바이트
uint64_t ivnc_rdp_received(ivnc_rdp *r);

#endif
