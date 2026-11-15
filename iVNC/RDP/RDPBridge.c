#include "RDPBridge.h"
#include <freerdp/freerdp.h>

const char *ivnc_freerdp_version(void) {
    return freerdp_get_version_string();
}
