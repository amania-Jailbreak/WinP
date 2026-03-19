#ifndef WINP_FREERDP_BRIDGE_H
#define WINP_FREERDP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef void (*winp_frame_callback_t)(const uint8_t* data, int width, int height, int stride,
									  void* userData);
typedef void (*winp_status_callback_t)(const char* status, void* userData);
typedef void (*winp_cursor_callback_t)(int kind, const uint8_t* data, int width, int height,
							   int hotspotX, int hotspotY,
							   void* userData);
const char* winp_freerdp_version_string(void);
int winp_freerdp_connect_test(const char* host, const char* username, const char* password,
								  const char* domain, char* errorOut, size_t errorOutSize);
int winp_freerdp_start_session(const char* host, const char* username, const char* password,
								   const char* domain, int width, int height, int fullscreen,
								   winp_frame_callback_t frameCallback,
								   winp_cursor_callback_t cursorCallback,
								   winp_status_callback_t statusCallback, void* userData,
								   char* errorOut, size_t errorOutSize);
int winp_freerdp_update_resolution(int width, int height, char* errorOut, size_t errorOutSize);
int winp_freerdp_send_mouse_event(uint16_t flags, uint16_t x, uint16_t y, char* errorOut,
							  size_t errorOutSize);
int winp_freerdp_send_unicode_key(int down, uint16_t code, char* errorOut, size_t errorOutSize);
int winp_freerdp_send_scancode_key(int down, uint32_t scancode, char* errorOut,
							   size_t errorOutSize);
void winp_freerdp_stop_session(void);

#endif
