/* Headers from which the Scheme FFI bindings are generated with c2ffi.
 * See tools/c2ffi-gen.ss and ffi/spec.ss for which declarations are used. */
#define _GNU_SOURCE 1
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <locale.h>
#include <wchar.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <termios.h>
#include <pty.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/timerfd.h>

#include <wayland-client-core.h>
#include <wayland-cursor.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_LCD_FILTER_H
#include <fontconfig/fontconfig.h>
