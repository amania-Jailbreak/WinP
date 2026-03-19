#include "FreeRDPBridge.h"

#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include <freerdp/display.h>
#include <freerdp/freerdp.h>
#include <freerdp/graphics.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/rail.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/ainput.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/channels/rdpdr.h>
#include <freerdp/channels/rdpsnd.h>
#include <freerdp/rail.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <freerdp/codec/color.h>
#include <freerdp/addin.h>
#include <winpr/assert.h>
#include <winpr/crt.h>
#include <winpr/synch.h>

typedef void (*winp_internal_remote_window_callback_t)(int eventKind, uint32_t windowId,
                                                       const char* title, int x, int y,
                                                       int width, int height, int visible,
                                                       void* userData);

typedef struct
{
	rdpContext context;
	winp_frame_callback_t frameCallback;
	winp_cursor_callback_t cursorCallback;
	winp_internal_remote_window_callback_t remoteWindowCallback;
	winp_status_callback_t statusCallback;
	void* userData;
	RailClientContext* railContext;
	BOOL railStartSent;
	BOOL railStartupIssued;
	BOOL railDesktopHooked;
	UINT32 railActiveWindowId;
	UINT32 railDesktopWindowCount;
	UINT32* railDesktopWindowIds;
	struct winp_rail_window_state* railWindows;
} winpContext;

typedef struct winp_rail_window_state
{
	UINT32 windowId;
	UINT32 ownerWindowId;
	UINT32 style;
	UINT32 extendedStyle;
	BOOL shown;
	BOOL activated;
	BOOL systemCommandSent;
	BOOL appIdRequested;
	BOOL cloaked;
	BOOL baselineWindow;
	BOOL remotePublished;
	UINT32 showState;
	char* title;
	INT32 clientOffsetX;
	INT32 clientOffsetY;
	UINT32 clientAreaWidth;
	UINT32 clientAreaHeight;
	UINT32 RPContent;
	UINT32 rootParentHandle;
	INT32 windowOffsetX;
	INT32 windowOffsetY;
	INT32 windowClientDeltaX;
	INT32 windowClientDeltaY;
	UINT32 windowWidth;
	UINT32 windowHeight;
	UINT32 numWindowRects;
	RECTANGLE_16* windowRects;
	INT32 visibleOffsetX;
	INT32 visibleOffsetY;
	UINT32 resizeMarginLeft;
	UINT32 resizeMarginTop;
	UINT32 resizeMarginRight;
	UINT32 resizeMarginBottom;
	UINT32 numVisibilityRects;
	RECTANGLE_16* visibilityRects;
	BYTE taskbarButton;
	UINT8 enforceServerZOrder;
	struct winp_rail_window_state* next;
} winpRailWindowState;

typedef struct
{
	rdpPointer pointer;
	BYTE* imageData;
	UINT32 imageLength;
} winpPointer;

typedef struct
{
	freerdp* instance;
	pthread_t thread;
	BOOL running;
	BOOL stopRequested;
	BOOL pendingResize;
	int pendingWidth;
	int pendingHeight;
	pthread_mutex_t lock;
	char errorText[1024];
} winpSession;

static winpRailWindowState* winp_find_or_create_rail_window(winpContext* context, UINT32 windowId);
static void winp_publish_remote_window_if_needed(winpContext* context,
                                                 winpRailWindowState* window);

static winpSession g_session = { .lock = PTHREAD_MUTEX_INITIALIZER };
static BOOL g_addinProviderRegistered = FALSE;
static BOOL g_minimalChannelMode = FALSE;

static BOOL winp_env_true(const char* name)
{
	const char* value = getenv(name);
	if (!value || (value[0] == '\0'))
		return FALSE;

	if ((_stricmp(value, "1") == 0) || (_stricmp(value, "true") == 0) ||
	    (_stricmp(value, "yes") == 0) || (_stricmp(value, "on") == 0))
	{
		return TRUE;
	}

	return FALSE;
}

extern BOOL VCAPITYPE rdpdr_VirtualChannelEntryEx(PCHANNEL_ENTRY_POINTS_EX pEntryPoints,
                                                   PVOID pInitHandle);
extern BOOL VCAPITYPE cliprdr_VirtualChannelEntryEx(PCHANNEL_ENTRY_POINTS_EX pEntryPoints,
                                                     PVOID pInitHandle);
extern BOOL VCAPITYPE drdynvc_VirtualChannelEntryEx(PCHANNEL_ENTRY_POINTS_EX pEntryPoints,
                                                     PVOID pInitHandle);
extern BOOL VCAPITYPE rail_VirtualChannelEntryEx(PCHANNEL_ENTRY_POINTS_EX pEntryPoints,
                                                  PVOID pInitHandle);
extern BOOL VCAPITYPE rdpsnd_VirtualChannelEntryEx(PCHANNEL_ENTRY_POINTS_EX pEntryPoints,
                                                    PVOID pInitHandle);
extern UINT VCAPITYPE ainput_DVCPluginEntry(IDRDYNVC_ENTRY_POINTS* pEntryPoints);
extern UINT VCAPITYPE disp_DVCPluginEntry(IDRDYNVC_ENTRY_POINTS* pEntryPoints);
extern UINT VCAPITYPE rdpgfx_DVCPluginEntry(IDRDYNVC_ENTRY_POINTS* pEntryPoints);
extern UINT VCAPITYPE rdpsnd_DVCPluginEntry(IDRDYNVC_ENTRY_POINTS* pEntryPoints);
extern UINT VCAPITYPE mac_freerdp_rdpsnd_client_subsystem_entry(void* pEntryPoints);
extern UINT VCAPITYPE fake_freerdp_rdpsnd_client_subsystem_entry(void* pEntryPoints);

enum
{
	WINP_CURSOR_KIND_CUSTOM = 0,
	WINP_CURSOR_KIND_DEFAULT = 1,
	WINP_CURSOR_KIND_HIDDEN = 2
};

static PVIRTUALCHANNELENTRY winp_load_static_addin_entry(const char* name,
                                                          const char* subsystem,
                                                          const char* type,
                                                          DWORD flags)
{
	const BOOL disableCliprdr = winp_env_true("WINP_DISABLE_CLIPRDR");
	const BOOL disableDrdynvc = winp_env_true("WINP_DISABLE_DRDYNVC");
	const BOOL disableRdpgfx = winp_env_true("WINP_DISABLE_RDPGFX");
	const BOOL disableRdpsnd = winp_env_true("WINP_DISABLE_RDPSND");

	WINPR_UNUSED(type);
	WINPR_UNUSED(flags);

	fprintf(stderr, "[WinP] addin-request name=%s subsystem=%s\n", name ? name : "(null)",
	        subsystem ? subsystem : "(null)");

	if (!name)
		return NULL;

	if (g_minimalChannelMode)
	{
		/* RemoteApp stability mode:
		 * keep only core static channels that must not fall back to dlopen().
		 */
		if ((strcmp(name, RDPDR_SVC_CHANNEL_NAME) == 0) &&
		    (!subsystem || (subsystem[0] == '\0')))
		{
			fprintf(stderr, "[WinP] addin-resolve rdpdr static (minimal)\n");
			return (PVIRTUALCHANNELENTRY)rdpdr_VirtualChannelEntryEx;
		}

		if ((strcmp(name, RAIL_SVC_CHANNEL_NAME) == 0) &&
		    (!subsystem || (subsystem[0] == '\0')))
		{
			fprintf(stderr, "[WinP] addin-resolve rail static (minimal)\n");
			return (PVIRTUALCHANNELENTRY)rail_VirtualChannelEntryEx;
		}

		if ((strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0) &&
		    (!subsystem || (subsystem[0] == '\0')))
		{
			if (disableCliprdr)
			{
				fprintf(stderr, "[WinP] addin-skip cliprdr disabled by env\n");
				return NULL;
			}
			fprintf(stderr, "[WinP] addin-resolve cliprdr static (minimal)\n");
			return (PVIRTUALCHANNELENTRY)cliprdr_VirtualChannelEntryEx;
		}

		if ((strcmp(name, DRDYNVC_SVC_CHANNEL_NAME) == 0) &&
		    (!subsystem || (subsystem[0] == '\0')))
		{
			if (disableDrdynvc)
			{
				fprintf(stderr, "[WinP] addin-skip drdynvc disabled by env\n");
				return NULL;
			}
			fprintf(stderr, "[WinP] addin-resolve drdynvc static (minimal)\n");
			return (PVIRTUALCHANNELENTRY)drdynvc_VirtualChannelEntryEx;
		}

		if ((strcmp(name, AINPUT_CHANNEL_NAME) == 0) &&
		    (!subsystem || (subsystem[0] == '\0')) &&
		    (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC))
		{
			if (disableDrdynvc)
			{
				fprintf(stderr, "[WinP] addin-skip ainput disabled by env\n");
				return NULL;
			}
			fprintf(stderr, "[WinP] addin-resolve ainput dynamic (minimal)\n");
			return (PVIRTUALCHANNELENTRY)ainput_DVCPluginEntry;
		}

		if ((strcmp(name, DISP_CHANNEL_NAME) == 0) &&
		    (!subsystem || (subsystem[0] == '\0')) &&
		    (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC))
		{
			if (disableDrdynvc)
			{
				fprintf(stderr, "[WinP] addin-skip disp disabled by env\n");
				return NULL;
			}
			fprintf(stderr, "[WinP] addin-resolve disp dynamic (minimal)\n");
			return (PVIRTUALCHANNELENTRY)disp_DVCPluginEntry;
		}

		if (((strcmp(name, "rdpgfx") == 0) || (strcmp(name, RDPGFX_DVC_CHANNEL_NAME) == 0)) &&
		    (!subsystem || (subsystem[0] == '\0')) &&
		    (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC))
		{
			if (disableDrdynvc || disableRdpgfx)
			{
				fprintf(stderr, "[WinP] addin-skip rdpgfx disabled by env\n");
				return NULL;
			}
			fprintf(stderr, "[WinP] addin-resolve rdpgfx dynamic (minimal)\n");
			return (PVIRTUALCHANNELENTRY)rdpgfx_DVCPluginEntry;
		}

		if (strcmp(name, RDPSND_CHANNEL_NAME) == 0)
		{
			if (disableRdpsnd || disableDrdynvc)
			{
				fprintf(stderr, "[WinP] addin-skip rdpsnd disabled by env\n");
				return NULL;
			}
			if (!subsystem || (subsystem[0] == '\0'))
			{
				if (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC)
				{
					fprintf(stderr, "[WinP] addin-resolve rdpsnd dynamic (minimal)\n");
					return (PVIRTUALCHANNELENTRY)rdpsnd_DVCPluginEntry;
				}

				fprintf(stderr, "[WinP] addin-resolve rdpsnd static (minimal)\n");
				return (PVIRTUALCHANNELENTRY)rdpsnd_VirtualChannelEntryEx;
			}

			if (_stricmp(subsystem, "fake") == 0)
			{
				fprintf(stderr, "[WinP] addin-resolve rdpsnd fake subsystem (minimal)\n");
				return (PVIRTUALCHANNELENTRY)fake_freerdp_rdpsnd_client_subsystem_entry;
			}

			if (_stricmp(subsystem, "mac") == 0)
			{
				fprintf(stderr, "[WinP] addin-resolve rdpsnd mac subsystem (minimal)\n");
				return (PVIRTUALCHANNELENTRY)mac_freerdp_rdpsnd_client_subsystem_entry;
			}
		}

		fprintf(stderr, "[WinP] addin-skip name=%s minimal-mode=1\n", name);
		return NULL;
	}

	if ((strcmp(name, RDPDR_SVC_CHANNEL_NAME) == 0) &&
	    (!subsystem || (subsystem[0] == '\0')))
	{
		fprintf(stderr, "[WinP] addin-resolve rdpdr static\n");
		return (PVIRTUALCHANNELENTRY)rdpdr_VirtualChannelEntryEx;
	}

	if ((strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0) &&
	    (!subsystem || (subsystem[0] == '\0')))
	{
		if (disableCliprdr)
		{
			fprintf(stderr, "[WinP] addin-skip cliprdr disabled by env\n");
			return NULL;
		}
		fprintf(stderr, "[WinP] addin-resolve cliprdr static\n");
		return (PVIRTUALCHANNELENTRY)cliprdr_VirtualChannelEntryEx;
	}

	if ((strcmp(name, DRDYNVC_SVC_CHANNEL_NAME) == 0) &&
	    (!subsystem || (subsystem[0] == '\0')))
	{
		if (disableDrdynvc)
		{
			fprintf(stderr, "[WinP] addin-skip drdynvc disabled by env\n");
			return NULL;
		}
		fprintf(stderr, "[WinP] addin-resolve drdynvc static\n");
		return (PVIRTUALCHANNELENTRY)drdynvc_VirtualChannelEntryEx;
	}

	if ((strcmp(name, RAIL_SVC_CHANNEL_NAME) == 0) &&
	    (!subsystem || (subsystem[0] == '\0')))
	{
		fprintf(stderr, "[WinP] addin-resolve rail static\n");
		return (PVIRTUALCHANNELENTRY)rail_VirtualChannelEntryEx;
	}

	if ((strcmp(name, AINPUT_CHANNEL_NAME) == 0) &&
	    (!subsystem || (subsystem[0] == '\0')) &&
	    (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC))
	{
		if (disableDrdynvc)
		{
			fprintf(stderr, "[WinP] addin-skip ainput disabled by env\n");
			return NULL;
		}
		fprintf(stderr, "[WinP] addin-resolve ainput dynamic\n");
		return (PVIRTUALCHANNELENTRY)ainput_DVCPluginEntry;
	}

	if ((strcmp(name, DISP_CHANNEL_NAME) == 0) &&
	    (!subsystem || (subsystem[0] == '\0')) &&
	    (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC))
	{
		if (disableDrdynvc)
		{
			fprintf(stderr, "[WinP] addin-skip disp disabled by env\n");
			return NULL;
		}
		fprintf(stderr, "[WinP] addin-resolve disp dynamic\n");
		return (PVIRTUALCHANNELENTRY)disp_DVCPluginEntry;
	}

	if (((strcmp(name, "rdpgfx") == 0) || (strcmp(name, RDPGFX_DVC_CHANNEL_NAME) == 0)) &&
	    (!subsystem || (subsystem[0] == '\0')) &&
	    (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC))
	{
		if (disableDrdynvc || disableRdpgfx)
		{
			fprintf(stderr, "[WinP] addin-skip rdpgfx disabled by env\n");
			return NULL;
		}
		fprintf(stderr, "[WinP] addin-resolve rdpgfx dynamic\n");
		return (PVIRTUALCHANNELENTRY)rdpgfx_DVCPluginEntry;
	}

	if (strcmp(name, RDPSND_CHANNEL_NAME) != 0)
		return NULL;

	if (disableRdpsnd || disableDrdynvc)
	{
		fprintf(stderr, "[WinP] addin-skip rdpsnd disabled by env\n");
		return NULL;
	}

	if (!subsystem || (subsystem[0] == '\0'))
	{
		if (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC)
		{
			fprintf(stderr, "[WinP] addin-resolve rdpsnd dynamic\n");
			return (PVIRTUALCHANNELENTRY)rdpsnd_DVCPluginEntry;
		}

		fprintf(stderr, "[WinP] addin-resolve rdpsnd static\n");
		return (PVIRTUALCHANNELENTRY)rdpsnd_VirtualChannelEntryEx;
	}

	if (_stricmp(subsystem, "mac") == 0)
	{
		fprintf(stderr, "[WinP] addin-resolve rdpsnd mac subsystem\n");
		return (PVIRTUALCHANNELENTRY)mac_freerdp_rdpsnd_client_subsystem_entry;
	}

	if (_stricmp(subsystem, "fake") == 0)
	{
		fprintf(stderr, "[WinP] addin-resolve rdpsnd fake subsystem\n");
		return (PVIRTUALCHANNELENTRY)fake_freerdp_rdpsnd_client_subsystem_entry;
	}

	return NULL;
}

static void winp_set_error(char* errorOut, size_t errorOutSize, const char* message)
{
	if (!errorOut || (errorOutSize == 0))
		return;

	if (!message)
	{
		errorOut[0] = '\0';
		return;
	}

	(void)snprintf(errorOut, errorOutSize, "%s", message);
}

static BOOL winp_set_setting(rdpSettings* settings, const char* name, const char* value)
{
	return freerdp_settings_set_value_for_name(settings, name, value);
}

static BOOL winp_apply_remote_app_settings(rdpSettings* settings, int remoteAppMode,
                                           const char* remoteAppName,
                                           const char* remoteAppProgram,
                                           const char* remoteAppCmdLine,
                                           const char* shellWorkingDirectory,
                                           const char* remoteApplicationFile,
                                           const char* remoteApplicationGuid,
                                           int remoteApplicationExpandCmdLine,
                                           int remoteApplicationExpandWorkingDir)
{
	if (!remoteAppMode)
		return TRUE;

	if (!remoteAppProgram || (strlen(remoteAppProgram) == 0))
		return FALSE;

	if (!winp_set_setting(settings, "FreeRDP_RemoteApplicationMode", "true") ||
	    !winp_set_setting(settings, "FreeRDP_RemoteApplicationProgram", remoteAppProgram) ||
	    !winp_set_setting(settings, "FreeRDP_RemoteApplicationSupportLevel", "1") ||
	    !winp_set_setting(settings, "FreeRDP_RemoteAppLanguageBarSupported", "true") ||
	    !winp_set_setting(settings, "FreeRDP_Workarea", "true") ||
	    !winp_set_setting(settings, "FreeRDP_DisableWallpaper", "true") ||
	    !winp_set_setting(settings, "FreeRDP_DisableFullWindowDrag", "true"))
	{
		return FALSE;
	}

	if (remoteAppName &&
	    !winp_set_setting(settings, "FreeRDP_RemoteApplicationName", remoteAppName))
	{
		return FALSE;
	}

	if (remoteAppCmdLine &&
	    !winp_set_setting(settings, "FreeRDP_RemoteApplicationCmdLine", remoteAppCmdLine))
	{
		return FALSE;
	}

	if (shellWorkingDirectory &&
	    !winp_set_setting(settings, "FreeRDP_ShellWorkingDirectory", shellWorkingDirectory))
	{
		return FALSE;
	}

	if (remoteApplicationFile &&
	    !winp_set_setting(settings, "FreeRDP_RemoteApplicationFile", remoteApplicationFile))
	{
		return FALSE;
	}

	if (remoteApplicationGuid &&
	    !winp_set_setting(settings, "FreeRDP_RemoteApplicationGuid", remoteApplicationGuid))
	{
		return FALSE;
	}

	if (!winp_set_setting(settings, "FreeRDP_RemoteApplicationExpandCmdLine",
	                      remoteApplicationExpandCmdLine ? "1" : "0") ||
	    !winp_set_setting(settings, "FreeRDP_RemoteApplicationExpandWorkingDir",
	                      remoteApplicationExpandWorkingDir ? "1" : "0"))
	{
		return FALSE;
	}

	fprintf(stderr,
	        "[WinP][rail] remoteapp settings program=%s name=%s cmd=%s workdir=%s file=%s guid=%s expandCmd=%d expandDir=%d\n",
	        remoteAppProgram ? remoteAppProgram : "(null)",
	        remoteAppName ? remoteAppName : "(null)",
	        remoteAppCmdLine ? remoteAppCmdLine : "(null)",
	        shellWorkingDirectory ? shellWorkingDirectory : "(null)",
	        remoteApplicationFile ? remoteApplicationFile : "(null)",
	        remoteApplicationGuid ? remoteApplicationGuid : "(null)",
	        remoteApplicationExpandCmdLine, remoteApplicationExpandWorkingDir);

	return TRUE;
}

static BOOL winp_enable_audio_addins(rdpContext* context, char* errorOut, size_t errorOutSize)
{
	ADDIN_ARGV* rdpdr = NULL;
	ADDIN_ARGV* rail = NULL;
	ADDIN_ARGV* rdpgfxDynamic = NULL;
	ADDIN_ARGV* rdpsndDynamic = NULL;
	const char* rdpsndSubsystem = NULL;
	const char* rdpsndArgs[2] = { RDPSND_CHANNEL_NAME, NULL };
	const char* rdpsndSysEnv = NULL;
	const char* const rdpdrArgs[] = { RDPDR_SVC_CHANNEL_NAME };
	const char* const railArgs[] = { RAIL_SVC_CHANNEL_NAME };
	const char* const rdpgfxArgs[] = { "rdpgfx" };
	const BOOL remoteAppMode = freerdp_settings_get_bool(context->settings, FreeRDP_RemoteApplicationMode);
	const BOOL minimalChannels = winp_env_true("WINP_MIN_CHANNELS");
	const BOOL disableCliprdr = winp_env_true("WINP_DISABLE_CLIPRDR");
	const BOOL disableDrdynvc = winp_env_true("WINP_DISABLE_DRDYNVC");
	const BOOL forceRdpgfx = winp_env_true("WINP_FORCE_RDPGFX");
	const BOOL enableRdpsndInRemoteApp = winp_env_true("WINP_ENABLE_RDPSND_IN_REMOTEAPP");
	const BOOL disableRdpgfx = winp_env_true("WINP_DISABLE_RDPGFX") || (remoteAppMode && !forceRdpgfx);
	const BOOL disableRdpsnd =
	    winp_env_true("WINP_DISABLE_RDPSND") || (remoteAppMode && !enableRdpsndInRemoteApp);

	WINPR_ASSERT(context);
	WINPR_ASSERT(context->settings);

	rdpsndSysEnv = getenv("WINP_RDPSND_SYS");
	if (rdpsndSysEnv && (rdpsndSysEnv[0] != '\0'))
	{
		if ((_stricmp(rdpsndSysEnv, "mac") == 0) || (_stricmp(rdpsndSysEnv, "fake") == 0))
			rdpsndSubsystem = (_stricmp(rdpsndSysEnv, "mac") == 0) ? "sys:mac" : "sys:fake";
	}

	if (!rdpsndSubsystem)
		rdpsndSubsystem = remoteAppMode ? "sys:fake" : "sys:mac";

	rdpsndArgs[1] = rdpsndSubsystem;

	if (!g_addinProviderRegistered)
	{
		const int rc = freerdp_register_addin_provider(winp_load_static_addin_entry, 0);
		if (rc != CHANNEL_RC_OK)
		{
			winp_set_error(errorOut, errorOutSize, "failed to register static addin provider");
			return FALSE;
		}
		g_addinProviderRegistered = TRUE;
	}

	if (minimalChannels)
	{
		fprintf(stderr, "[WinP] minimal channels mode enabled (env=%d remoteapp=%d)\n",
		        winp_env_true("WINP_MIN_CHANNELS") ? 1 : 0, remoteAppMode ? 1 : 0);

		/* Hard-prune channel collections so cmdline/.rdp defaults cannot re-enable
		 * drdynvc/rdpsnd/ainput/disp via fallback dynamic loading.
		 */
		freerdp_dynamic_channel_collection_free(context->settings);
		freerdp_static_channel_collection_free(context->settings);

		rdpdr = freerdp_addin_argv_new(ARRAYSIZE(rdpdrArgs), rdpdrArgs);
		rail = freerdp_addin_argv_new(ARRAYSIZE(railArgs), railArgs);
		if (!rdpdr || !rail ||
		    !freerdp_static_channel_collection_add(context->settings, rdpdr) ||
		    !freerdp_static_channel_collection_add(context->settings, rail))
		{
			freerdp_addin_argv_free(rdpdr);
			freerdp_addin_argv_free(rail);
			winp_set_error(errorOut, errorOutSize,
			               "failed to configure minimal static channels");
			return FALSE;
		}

		if (!freerdp_settings_set_bool(context->settings, FreeRDP_AudioPlayback, FALSE) ||
		    !freerdp_settings_set_bool(context->settings, FreeRDP_DeviceRedirection, FALSE) ||
		    !freerdp_settings_set_bool(context->settings, FreeRDP_RedirectClipboard, FALSE) ||
		    !freerdp_settings_set_bool(context->settings, FreeRDP_SupportDisplayControl, FALSE) ||
		    !freerdp_settings_set_bool(context->settings, FreeRDP_SupportDynamicChannels, FALSE))
		{
			winp_set_error(errorOut, errorOutSize, "failed to apply minimal channel settings");
			return FALSE;
		}

		fprintf(stderr, "[WinP] minimal channels active: static=[rdpdr,rail] dynamic=[]\n");
		return TRUE;
	}

	if (!freerdp_settings_set_bool(context->settings, FreeRDP_AudioPlayback, TRUE))
	{
		winp_set_error(errorOut, errorOutSize, "failed to enable audio playback setting");
		return FALSE;
	}

	if (disableRdpsnd || disableDrdynvc)
	{
		if (!freerdp_settings_set_bool(context->settings, FreeRDP_AudioPlayback, FALSE))
		{
			winp_set_error(errorOut, errorOutSize, "failed to disable audio playback setting");
			return FALSE;
		}
	}

	if (!freerdp_settings_set_bool(context->settings, FreeRDP_DeviceRedirection, TRUE))
	{
		winp_set_error(errorOut, errorOutSize, "failed to enable device redirection");
		return FALSE;
	}

	if (!freerdp_settings_set_bool(context->settings, FreeRDP_SupportDynamicChannels, TRUE))
	{
		winp_set_error(errorOut, errorOutSize, "failed to enable dynamic channels");
		return FALSE;
	}

	if (disableDrdynvc)
	{
		if (!freerdp_settings_set_bool(context->settings, FreeRDP_SupportDynamicChannels, FALSE))
		{
			winp_set_error(errorOut, errorOutSize, "failed to disable dynamic channels");
			return FALSE;
		}
	}

	if (disableCliprdr)
	{
		(void)freerdp_settings_set_bool(context->settings, FreeRDP_RedirectClipboard, FALSE);
		(void)freerdp_static_channel_collection_del(context->settings, CLIPRDR_SVC_CHANNEL_NAME);
	}

	if (disableDrdynvc)
	{
		(void)freerdp_static_channel_collection_del(context->settings, DRDYNVC_SVC_CHANNEL_NAME);
		(void)freerdp_dynamic_channel_collection_del(context->settings, RDPSND_CHANNEL_NAME);
		(void)freerdp_dynamic_channel_collection_del(context->settings, "rdpgfx");
		(void)freerdp_dynamic_channel_collection_del(context->settings, AINPUT_CHANNEL_NAME);
		(void)freerdp_dynamic_channel_collection_del(context->settings, DISP_CHANNEL_NAME);
	}

	if (disableRdpgfx)
	{
		(void)freerdp_dynamic_channel_collection_del(context->settings, "rdpgfx");
	}

	if (disableRdpsnd)
	{
		(void)freerdp_static_channel_collection_del(context->settings, RDPSND_CHANNEL_NAME);
		(void)freerdp_dynamic_channel_collection_del(context->settings, RDPSND_CHANNEL_NAME);
	}

	/* In non-minimal mode, don't force-add rdpdr here.
	 * Device redirection / parsed settings already provide it, and an extra add
	 * can duplicate static channel registration.
	 */

	if (!disableDrdynvc && !disableRdpgfx &&
	    !freerdp_dynamic_channel_collection_find(context->settings, "rdpgfx"))
	{
		rdpgfxDynamic = freerdp_addin_argv_new(ARRAYSIZE(rdpgfxArgs), rdpgfxArgs);
		if (!rdpgfxDynamic ||
		    !freerdp_dynamic_channel_collection_add(context->settings, rdpgfxDynamic))
		{
			freerdp_addin_argv_free(rdpgfxDynamic);
			winp_set_error(errorOut, errorOutSize, "failed to register dynamic rdpgfx channel");
			return FALSE;
		}
	}

	if (!disableRdpsnd && !disableDrdynvc &&
	    !freerdp_dynamic_channel_collection_find(context->settings, RDPSND_CHANNEL_NAME))
	{
		rdpsndDynamic = freerdp_addin_argv_new(ARRAYSIZE(rdpsndArgs), rdpsndArgs);
		if (!rdpsndDynamic ||
		    !freerdp_dynamic_channel_collection_add(context->settings, rdpsndDynamic))
		{
			freerdp_addin_argv_free(rdpsndDynamic);
			winp_set_error(errorOut, errorOutSize, "failed to register dynamic rdpsnd channel");
			return FALSE;
		}
	}

	fprintf(stderr,
	        "[WinP] audio-addins enabled: playback=%d device-redirection=1 rdpsnd=%s rdpgfx=%d cliprdr=%d drdynvc=%d force-rdpgfx=%d remoteapp-rdpsnd-optin=%d\n",
	        (disableRdpsnd || disableDrdynvc) ? 0 : 1,
	        (disableRdpsnd || disableDrdynvc) ? "disabled" : rdpsndSubsystem,
	        (disableDrdynvc || disableRdpgfx) ? 0 : 1,
	        disableCliprdr ? 0 : 1, disableDrdynvc ? 0 : 1, forceRdpgfx ? 1 : 0,
	        enableRdpsndInRemoteApp ? 1 : 0);

	return TRUE;
}

static void winp_status(winpContext* context, const char* message)
{
	if (message)
		fprintf(stderr, "[WinP] %s\n", message);
	if (context && context->statusCallback)
		context->statusCallback(message, context->userData);
}

static void winp_remote_window_event(winpContext* context, int eventKind, UINT32 windowId,
                                     const winpRailWindowState* window)
{
	const char* title = "";
	int x = 0;
	int y = 0;
	int width = 0;
	int height = 0;
	int visible = 0;

	if (window)
	{
		title = window->title ? window->title : "";
		x = window->windowOffsetX;
		y = window->windowOffsetY;
		width = WINPR_ASSERTING_INT_CAST(int, window->windowWidth);
		height = WINPR_ASSERTING_INT_CAST(int, window->windowHeight);
		visible = window->shown ? 1 : 0;
	}

	fprintf(stderr,
	        "[WinP][rail-window] dispatch event=%d id=0x%08" PRIX32
	        " title=%s frame=%d,%d %dx%d visible=%d callback=%p\n",
	        eventKind, windowId, title, x, y, width, height, visible,
	        context ? (void*)context->remoteWindowCallback : NULL);

	if (!context || !context->remoteWindowCallback)
		return;

	context->remoteWindowCallback(eventKind, windowId, title, x, y, width, height, visible,
	                              context->userData);
}

static UINT winp_rail_server_execute_result(RailClientContext* rail,
                                            const RAIL_EXEC_RESULT_ORDER* execResult)
{
	winpContext* context = rail ? (winpContext*)rail->custom : NULL;

	if (!execResult)
		return CHANNEL_RC_OK;

	fprintf(stderr, "[WinP][rail] execute result=0x%08" PRIX32 " raw=0x%08" PRIX32 "\n",
	        execResult->execResult, execResult->rawResult);

	if (execResult->execResult != RAIL_EXEC_S_OK)
		winp_status(context, "rail-exec-failed");

	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_system_param(RailClientContext* rail,
                                          const RAIL_SYSPARAM_ORDER* sysparam)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(sysparam);
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_local_move_size(RailClientContext* rail,
                                             const RAIL_LOCALMOVESIZE_ORDER* localMoveSize)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(localMoveSize);
	fprintf(stderr, "[WinP][rail] local move size\n");
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_min_max_info(RailClientContext* rail,
                                          const RAIL_MINMAXINFO_ORDER* minMaxInfo)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(minMaxInfo);
	fprintf(stderr, "[WinP][rail] min max info\n");
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_language_bar_info(RailClientContext* rail,
                                               const RAIL_LANGBAR_INFO_ORDER* langBarInfo)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(langBarInfo);
	fprintf(stderr, "[WinP][rail] language bar info\n");
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_get_appid_response(RailClientContext* rail,
                                                const RAIL_GET_APPID_RESP_ORDER* getAppIdResp)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(getAppIdResp);
	fprintf(stderr, "[WinP][rail] get appid response\n");
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_taskbar_info(RailClientContext* rail,
                                          const RAIL_TASKBAR_INFO_ORDER* taskBarInfo)
{
	WINPR_UNUSED(rail);
	fprintf(stderr,
	        "[WinP][rail] taskbar info message=0x%08" PRIX32 " tab=0x%08" PRIX32
	        " body=0x%08" PRIX32 "\n",
	        taskBarInfo ? taskBarInfo->TaskbarMessage : 0,
	        taskBarInfo ? taskBarInfo->WindowIdTab : 0, taskBarInfo ? taskBarInfo->Body : 0);
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_zorder_sync(RailClientContext* rail, const RAIL_ZORDER_SYNC* zorder)
{
	WINPR_UNUSED(rail);
	fprintf(stderr, "[WinP][rail] zorder sync marker=0x%08" PRIX32 "\n",
	        zorder ? zorder->windowIdMarker : 0);
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_cloak(RailClientContext* rail, const RAIL_CLOAK* cloak)
{
	winpContext* context = rail ? (winpContext*)rail->custom : NULL;
	winpRailWindowState* window = NULL;
	if (context && cloak)
	{
		window = winp_find_or_create_rail_window(context, cloak->windowId);
		if (window)
		{
			window->cloaked = cloak->cloak;
			window->shown = cloak->cloak ? FALSE : window->shown;
			winp_publish_remote_window_if_needed(context, window);
		}
	}
	fprintf(stderr, "[WinP][rail] cloak window id=0x%08" PRIX32 " cloaked=%d\n",
	        cloak ? cloak->windowId : 0, cloak ? (int)cloak->cloak : 0);
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_power_display_request(RailClientContext* rail,
                                                   const RAIL_POWER_DISPLAY_REQUEST* power)
{
	WINPR_UNUSED(rail);
	fprintf(stderr, "[WinP][rail] power display request active=%" PRIu32 "\n",
	        power ? power->active : 0);
	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_get_appid_response_ex(RailClientContext* rail,
                                                   const RAIL_GET_APPID_RESP_EX* id)
{
	winpContext* context = rail ? (winpContext*)rail->custom : NULL;
	winpRailWindowState* window = NULL;
	if (context && id)
	{
		window = winp_find_or_create_rail_window(context, id->windowID);
		if (window)
			window->appIdRequested = TRUE;
	}
	fprintf(stderr, "[WinP][rail] get appid response ex window=0x%08" PRIX32 " pid=%" PRIu32 "\n",
	        id ? id->windowID : 0, id ? id->processId : 0);
	return CHANNEL_RC_OK;
}

static UINT winp_send_rail_client_information(winpContext* context)
{
	RAIL_CLIENT_STATUS_ORDER clientStatus = WINPR_C_ARRAY_INIT;
	UINT status = CHANNEL_RC_OK;

	if (!context || !context->railContext || !context->context.settings)
		return ERROR_INVALID_PARAMETER;

	/* Compatibility-first: keep client status minimal. */
	clientStatus.flags = TS_RAIL_CLIENTSTATUS_ALLOWLOCALMOVESIZE;

	if (freerdp_settings_get_bool(context->context.settings, FreeRDP_AutoReconnectionEnabled))
		clientStatus.flags |= TS_RAIL_CLIENTSTATUS_AUTORECONNECT;

	status = context->railContext->ClientInformation(context->railContext, &clientStatus);
	fprintf(stderr, "[WinP][rail] client information rc=%" PRIu32 " flags=0x%08" PRIX32 "\n",
	        status, clientStatus.flags);
	return status;
}

static UINT winp_send_rail_client_language_bar(winpContext* context)
{
	RAIL_LANGBAR_INFO_ORDER langBarInfo = WINPR_C_ARRAY_INIT;
	UINT status = CHANNEL_RC_OK;

	if (!context || !context->railContext)
		return ERROR_INVALID_PARAMETER;

	langBarInfo.languageBarStatus = TF_SFT_HIDDEN;
	status = context->railContext->ClientLanguageBarInfo(context->railContext, &langBarInfo);
	fprintf(stderr, "[WinP][rail] client language bar rc=%" PRIu32 " status=0x%08" PRIX32 "\n",
	        status, langBarInfo.languageBarStatus);
	return status;
}

static UINT winp_send_rail_client_system_params(winpContext* context)
{
	RAIL_SYSPARAM_ORDER sysparam = WINPR_C_ARRAY_INIT;
	UINT status = CHANNEL_RC_OK;
	UINT32 w = 0;
	UINT32 h = 0;
	UINT32 right = 0;
	UINT32 bottom = 0;

	if (!context || !context->railContext || !context->context.settings)
		return ERROR_INVALID_PARAMETER;

	w = freerdp_settings_get_uint32(context->context.settings, FreeRDP_DesktopWidth);
	h = freerdp_settings_get_uint32(context->context.settings, FreeRDP_DesktopHeight);
	right = (w > 0) ? (w - 1) : 0;
	bottom = (h > 0) ? (h - 1) : 0;

	/* Compatibility-first: only advertise work area. */
	sysparam.params = SPI_MASK_SET_WORK_AREA;
	sysparam.workArea.left = 0;
	sysparam.workArea.top = 0;
	sysparam.workArea.right = WINPR_ASSERTING_INT_CAST(UINT16, right);
	sysparam.workArea.bottom = WINPR_ASSERTING_INT_CAST(UINT16, bottom);

	status = context->railContext->ClientSystemParam(context->railContext, &sysparam);
	fprintf(stderr, "[WinP][rail] client system param rc=%" PRIu32 " workarea=%" PRIu32 "x%" PRIu32 "\n",
	        status, w, h);
	return status;
}

static void winp_send_optional_rail_orders(winpContext* context)
{
	RAIL_COMPARTMENT_INFO_ORDER compartment = WINPR_C_ARRAY_INIT;
	RAIL_LANGUAGEIME_INFO_ORDER imeInfo = WINPR_C_ARRAY_INIT;
	UINT status = CHANNEL_RC_OK;

	if (!context || !context->railContext)
		return;

	if (context->railContext->ClientCompartmentInfo)
	{
		status = context->railContext->ClientCompartmentInfo(context->railContext, &compartment);
		fprintf(stderr, "[WinP][rail] client compartment rc=%" PRIu32 "\n", status);
	}

	imeInfo.ProfileType = TF_PROFILETYPE_KEYBOARDLAYOUT;
	imeInfo.LanguageID = 0x0411;
	if (context->railContext->ClientLanguageIMEInfo)
	{
		status = context->railContext->ClientLanguageIMEInfo(context->railContext, &imeInfo);
		fprintf(stderr, "[WinP][rail] client ime info rc=%" PRIu32 "\n", status);
	}

	if (context->railContext->ClientTextScale)
	{
		status = context->railContext->ClientTextScale(context->railContext, 100);
		fprintf(stderr, "[WinP][rail] client text scale rc=%" PRIu32 " value=100\n", status);
	}

	if (context->railContext->ClientCaretBlinkRate)
	{
		status = context->railContext->ClientCaretBlinkRate(context->railContext, 530);
		fprintf(stderr, "[WinP][rail] client caret blink rc=%" PRIu32 " value=530\n", status);
	}
}

static UINT winp_send_rail_execute(winpContext* context)
{
	static const char kEmpty[] = "";
	char argsAndFile[520] = WINPR_C_ARRAY_INIT;
	RAIL_EXEC_ORDER exec = WINPR_C_ARRAY_INIT;
	const rdpSettings* settings = NULL;
	const char* remoteApplicationFile = NULL;
	const char* remoteApplicationCmdLine = NULL;
	const char* remoteApplicationProgram = NULL;
	const char* shellWorkingDirectory = NULL;
	const char* remoteApplicationGuid = NULL;

	if (!context || !context->railContext || !context->context.settings)
		return ERROR_INVALID_PARAMETER;

	settings = context->context.settings;
	remoteApplicationFile =
	    freerdp_settings_get_string(settings, FreeRDP_RemoteApplicationFile);
	remoteApplicationCmdLine =
	    freerdp_settings_get_string(settings, FreeRDP_RemoteApplicationCmdLine);
	remoteApplicationProgram =
	    freerdp_settings_get_string(settings, FreeRDP_RemoteApplicationProgram);
	shellWorkingDirectory =
	    freerdp_settings_get_string(settings, FreeRDP_ShellWorkingDirectory);
	remoteApplicationGuid =
	    freerdp_settings_get_string(settings, FreeRDP_RemoteApplicationGuid);

	if (remoteApplicationCmdLine && (remoteApplicationCmdLine[0] == '\0'))
		remoteApplicationCmdLine = NULL;
	if (shellWorkingDirectory && (shellWorkingDirectory[0] == '\0'))
		shellWorkingDirectory = NULL;
	if (remoteApplicationFile && (remoteApplicationFile[0] == '\0'))
		remoteApplicationFile = NULL;
	if (remoteApplicationGuid && (remoteApplicationGuid[0] == '\0'))
		remoteApplicationGuid = NULL;

	if ((freerdp_settings_get_uint32(settings, FreeRDP_RemoteApplicationExpandCmdLine) != 0) &&
	    remoteApplicationCmdLine)
		exec.flags |= TS_RAIL_EXEC_FLAG_EXPAND_ARGUMENTS;
	if ((freerdp_settings_get_uint32(settings, FreeRDP_RemoteApplicationExpandWorkingDir) != 0) &&
	    shellWorkingDirectory)
		exec.flags |= TS_RAIL_EXEC_FLAG_EXPAND_WORKINGDIRECTORY;
	if (remoteApplicationFile)
		exec.flags |= TS_RAIL_EXEC_FLAG_FILE;
	if (remoteApplicationGuid)
		exec.flags |= TS_RAIL_EXEC_FLAG_APP_USER_MODEL_ID;

	if (remoteApplicationFile && remoteApplicationCmdLine)
	{
		(void)_snprintf(argsAndFile, ARRAYSIZE(argsAndFile), "%s %s", remoteApplicationCmdLine,
		                remoteApplicationFile);
		exec.RemoteApplicationArguments = argsAndFile;
	}
	else if (remoteApplicationFile)
		exec.RemoteApplicationArguments = remoteApplicationFile;
	else if (remoteApplicationGuid)
		exec.RemoteApplicationArguments = remoteApplicationGuid;
	else
		exec.RemoteApplicationArguments = remoteApplicationCmdLine;

	exec.RemoteApplicationProgram = remoteApplicationProgram ? remoteApplicationProgram : kEmpty;
	exec.RemoteApplicationWorkingDir = shellWorkingDirectory ? shellWorkingDirectory : kEmpty;
	if (!exec.RemoteApplicationArguments)
		exec.RemoteApplicationArguments = kEmpty;

	fprintf(stderr,
	        "[WinP][rail] client execute flags=0x%04" PRIX16 " program=%s workdir=%s args=%s\n",
	        exec.flags, exec.RemoteApplicationProgram ? exec.RemoteApplicationProgram : "(null)",
	        exec.RemoteApplicationWorkingDir ? exec.RemoteApplicationWorkingDir : "(null)",
	        exec.RemoteApplicationArguments ? exec.RemoteApplicationArguments : "(null)");
	return context->railContext->ClientExecute(context->railContext, &exec);
}

static UINT winp_send_rail_startup_orders(winpContext* context)
{
	UINT rc = CHANNEL_RC_OK;
	const BOOL execOnly = winp_env_true("WINP_RAIL_EXEC_ONLY");

	if (!context || !context->railContext)
		return ERROR_INVALID_PARAMETER;

	if (!context->context.settings ||
	    !freerdp_settings_get_bool(context->context.settings, FreeRDP_RemoteApplicationMode))
	{
		fprintf(stderr, "[WinP][rail] startup skipped (RemoteApplicationMode=0)\n");
		return CHANNEL_RC_OK;
	}

	if (execOnly)
	{
		fprintf(stderr,
		        "[WinP][rail] startup mode=exec-only (RemoteApplicationMode=1, env WINP_RAIL_EXEC_ONLY=1)\n");
		return winp_send_rail_execute(context);
	}

	fprintf(stderr, "[WinP][rail] startup mode=minimal (RemoteApplicationMode=1)\n");
	rc = winp_send_rail_client_information(context);
	if (rc != CHANNEL_RC_OK)
		return rc;

	rc = winp_send_rail_client_system_params(context);
	if (rc != CHANNEL_RC_OK)
		return rc;

	return winp_send_rail_execute(context);
}

static void winp_request_rail_appid(winpContext* context, UINT32 windowId)
{
	RAIL_GET_APPID_REQ_ORDER req = WINPR_C_ARRAY_INIT;
	winpRailWindowState* window = NULL;
	UINT status = CHANNEL_RC_OK;

	if (!context || !context->railContext || (windowId == 0))
		return;

	if (!context->railContext->ClientGetAppIdRequest)
		return;

	window = winp_find_or_create_rail_window(context, windowId);
	if (!window || window->appIdRequested)
		return;

	req.windowId = windowId;
	status = context->railContext->ClientGetAppIdRequest(context->railContext, &req);
	fprintf(stderr, "[WinP][rail] client get appid request window=0x%08" PRIX32 " rc=%" PRIu32 "\n",
	        windowId, status);
	if (status == CHANNEL_RC_OK)
		window->appIdRequested = TRUE;
}

static winpRailWindowState* winp_find_or_create_rail_window(winpContext* context, UINT32 windowId)
{
	winpRailWindowState* cur = NULL;

	WINPR_ASSERT(context);

	for (cur = context->railWindows; cur; cur = cur->next)
	{
		if (cur->windowId == windowId)
			return cur;
	}

	cur = (winpRailWindowState*)calloc(1, sizeof(winpRailWindowState));
	if (!cur)
		return NULL;

	cur->windowId = windowId;
	cur->next = context->railWindows;
	context->railWindows = cur;
	return cur;
}

static void winp_remove_rail_window(winpContext* context, UINT32 windowId)
{
	winpRailWindowState* cur = NULL;
	winpRailWindowState* prev = NULL;

	if (!context)
		return;

	for (cur = context->railWindows; cur; prev = cur, cur = cur->next)
	{
		if (cur->windowId != windowId)
			continue;

		if (prev)
			prev->next = cur->next;
		else
			context->railWindows = cur->next;

		if (cur->remotePublished)
			winp_remote_window_event(context, 1, windowId, cur);

		free(cur->title);
		free(cur->windowRects);
		free(cur->visibilityRects);
		free(cur);
		return;
	}
}

static void winp_clear_rail_windows(winpContext* context)
{
	winpRailWindowState* cur = NULL;

	if (!context)
		return;

	cur = context->railWindows;
	while (cur)
	{
		winpRailWindowState* next = cur->next;
		free(cur->title);
		free(cur->windowRects);
		free(cur->visibilityRects);
		free(cur);
		cur = next;
	}

	context->railWindows = NULL;
}

static void winp_clear_rail_desktop_state(winpContext* context)
{
	if (!context)
		return;

	free(context->railDesktopWindowIds);
	context->railDesktopWindowIds = NULL;
	context->railDesktopWindowCount = 0;
	context->railActiveWindowId = 0;
	context->railDesktopHooked = FALSE;
}

static char* winp_dup_rail_string(const RAIL_UNICODE_STRING* str)
{
	const WCHAR* wide = NULL;

	if (!str)
		return NULL;

	if (str->length == 0)
		return _strdup("");

	wide = (const WCHAR*)str->string;
	return ConvertWCharNToUtf8Alloc(wide, str->length / sizeof(WCHAR), NULL);
}

static BOOL winp_copy_rects(RECTANGLE_16** dstRects, UINT32* dstCount, const RECTANGLE_16* srcRects,
                            UINT32 srcCount)
{
	RECTANGLE_16* copied = NULL;

	if (!dstRects || !dstCount)
		return FALSE;

	free(*dstRects);
	*dstRects = NULL;
	*dstCount = 0;

	if (!srcRects || (srcCount == 0))
		return TRUE;

	copied = (RECTANGLE_16*)calloc(srcCount, sizeof(RECTANGLE_16));
	if (!copied)
		return FALSE;

	CopyMemory(copied, srcRects, srcCount * sizeof(RECTANGLE_16));
	*dstRects = copied;
	*dstCount = srcCount;
	return TRUE;
}

static BOOL winp_copy_window_ids(UINT32** dstIds, UINT32* dstCount, const UINT32* srcIds,
                                 UINT32 srcCount)
{
	UINT32* copied = NULL;

	if (!dstIds || !dstCount)
		return FALSE;

	free(*dstIds);
	*dstIds = NULL;
	*dstCount = 0;

	if (!srcIds || (srcCount == 0))
		return TRUE;

	copied = (UINT32*)calloc(srcCount, sizeof(UINT32));
	if (!copied)
		return FALSE;

	CopyMemory(copied, srcIds, srcCount * sizeof(UINT32));
	*dstIds = copied;
	*dstCount = srcCount;
	return TRUE;
}

static BOOL winp_window_id_in_list(const UINT32* ids, UINT32 count, UINT32 windowId)
{
	UINT32 index = 0;

	if (!ids || (count == 0))
		return FALSE;

	for (index = 0; index < count; index++)
	{
		if (ids[index] == windowId)
			return TRUE;
	}

	return FALSE;
}

static BOOL winp_update_rail_window_state(winpRailWindowState* window,
                                          const WINDOW_ORDER_INFO* orderInfo,
                                          const WINDOW_STATE_ORDER* windowState)
{
	UINT32 fieldFlags = 0;

	if (!window || !orderInfo || !windowState)
		return FALSE;

	fieldFlags = orderInfo->fieldFlags;

	if ((fieldFlags & WINDOW_ORDER_STATE_NEW) != 0)
	{
		window->ownerWindowId = windowState->ownerWindowId;
		window->style = windowState->style;
		window->extendedStyle = windowState->extendedStyle;
		window->clientOffsetX = windowState->clientOffsetX;
		window->clientOffsetY = windowState->clientOffsetY;
		window->clientAreaWidth = windowState->clientAreaWidth;
		window->clientAreaHeight = windowState->clientAreaHeight;
		window->RPContent = windowState->RPContent;
		window->rootParentHandle = windowState->rootParentHandle;
		window->windowOffsetX = windowState->windowOffsetX;
		window->windowOffsetY = windowState->windowOffsetY;
		window->windowClientDeltaX = windowState->windowClientDeltaX;
		window->windowClientDeltaY = windowState->windowClientDeltaY;
		window->windowWidth = windowState->windowWidth;
		window->windowHeight = windowState->windowHeight;
		window->visibleOffsetX = windowState->visibleOffsetX;
		window->visibleOffsetY = windowState->visibleOffsetY;
		window->resizeMarginLeft = windowState->resizeMarginLeft;
		window->resizeMarginTop = windowState->resizeMarginTop;
		window->resizeMarginRight = windowState->resizeMarginRight;
		window->resizeMarginBottom = windowState->resizeMarginBottom;
		window->taskbarButton = windowState->TaskbarButton;
		window->enforceServerZOrder = windowState->EnforceServerZOrder;
	}

	if ((fieldFlags & WINDOW_ORDER_FIELD_OWNER) != 0)
		window->ownerWindowId = windowState->ownerWindowId;
	if ((fieldFlags & WINDOW_ORDER_FIELD_STYLE) != 0)
	{
		window->style = windowState->style;
		window->extendedStyle = windowState->extendedStyle;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_SHOW) != 0)
		window->showState = windowState->showState;
	if ((fieldFlags & WINDOW_ORDER_FIELD_CLIENT_AREA_OFFSET) != 0)
	{
		window->clientOffsetX = windowState->clientOffsetX;
		window->clientOffsetY = windowState->clientOffsetY;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_CLIENT_AREA_SIZE) != 0)
	{
		window->clientAreaWidth = windowState->clientAreaWidth;
		window->clientAreaHeight = windowState->clientAreaHeight;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_RP_CONTENT) != 0)
		window->RPContent = windowState->RPContent;
	if ((fieldFlags & WINDOW_ORDER_FIELD_ROOT_PARENT) != 0)
		window->rootParentHandle = windowState->rootParentHandle;
	if ((fieldFlags & WINDOW_ORDER_FIELD_WND_OFFSET) != 0)
	{
		window->windowOffsetX = windowState->windowOffsetX;
		window->windowOffsetY = windowState->windowOffsetY;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_WND_CLIENT_DELTA) != 0)
	{
		window->windowClientDeltaX = windowState->windowClientDeltaX;
		window->windowClientDeltaY = windowState->windowClientDeltaY;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_WND_SIZE) != 0)
	{
		window->windowWidth = windowState->windowWidth;
		window->windowHeight = windowState->windowHeight;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_VIS_OFFSET) != 0)
	{
		window->visibleOffsetX = windowState->visibleOffsetX;
		window->visibleOffsetY = windowState->visibleOffsetY;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_RESIZE_MARGIN_X) != 0)
	{
		window->resizeMarginLeft = windowState->resizeMarginLeft;
		window->resizeMarginRight = windowState->resizeMarginRight;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_RESIZE_MARGIN_Y) != 0)
	{
		window->resizeMarginTop = windowState->resizeMarginTop;
		window->resizeMarginBottom = windowState->resizeMarginBottom;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_TITLE) != 0)
	{
		char* title = winp_dup_rail_string(&windowState->titleInfo);
		if (!title)
			return FALSE;
		free(window->title);
		window->title = title;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_WND_RECTS) != 0)
	{
		if (!winp_copy_rects(&window->windowRects, &window->numWindowRects,
		                     windowState->windowRects, windowState->numWindowRects))
			return FALSE;
	}
	if ((fieldFlags & WINDOW_ORDER_FIELD_VISIBILITY) != 0)
	{
		if (!winp_copy_rects(&window->visibilityRects, &window->numVisibilityRects,
		                     windowState->visibilityRects, windowState->numVisibilityRects))
			return FALSE;
	}

	return TRUE;
}

static void winp_try_activate_rail_window(winpContext* context, UINT32 windowId)
{
	RAIL_ACTIVATE_ORDER activate = WINPR_C_ARRAY_INIT;
	winpRailWindowState* window = NULL;
	UINT rc = CHANNEL_RC_OK;

	if (!context || !context->railContext)
		return;

	window = winp_find_or_create_rail_window(context, windowId);
	if (!window || window->activated)
		return;

	activate.windowId = windowId;
	activate.enabled = TRUE;
	rc = context->railContext->ClientActivate(context->railContext, &activate);
	fprintf(stderr, "[WinP][rail] activate window id=0x%08" PRIX32 " rc=%" PRIu32 "\n", windowId,
	        rc);

	if (rc == CHANNEL_RC_OK)
		window->activated = TRUE;
}

static void winp_try_send_rail_system_command(winpContext* context, UINT32 windowId);

static BOOL winp_is_window_publishable(const winpContext* context,
                                       const winpRailWindowState* window)
{
	const UINT32 WS_EX_TOOLWINDOW_MASK = 0x00000080U;
	const UINT32 WS_EX_NOACTIVATE_MASK = 0x08000000U;
	const UINT32 activeWindowId = context ? context->railActiveWindowId : 0;

	if (!window)
		return FALSE;
	if (window->ownerWindowId != 0)
		return FALSE;
	if (window->cloaked)
		return FALSE;
	if ((window->extendedStyle & (WS_EX_TOOLWINDOW_MASK | WS_EX_NOACTIVATE_MASK)) != 0)
		return FALSE;
	if (window->showState == WINDOW_HIDE)
		return FALSE;
	if ((window->windowWidth == 0) || (window->windowHeight == 0))
		return FALSE;
	/* In RemoteApp we only publish the currently active top-level window.
	 * This avoids flooding the app layer with transient/duplicate shell windows.
	 */
	if ((activeWindowId != 0) && (activeWindowId != UINT32_MAX) &&
	    (window->windowId != activeWindowId))
	{
		return FALSE;
	}
	return TRUE;
}

static void winp_publish_remote_window_if_needed(winpContext* context, winpRailWindowState* window)
{
	const BOOL publishable = winp_is_window_publishable(context, window);

	if (!context || !window)
		return;

	fprintf(stderr,
	        "[WinP][rail-window] evaluate id=0x%08" PRIX32
	        " shown=%d published=%d baseline=%d startSent=%d owner=0x%08" PRIX32
	        " exstyle=0x%08" PRIX32 " active=0x%08" PRIX32 " size=%" PRIu32 "x%" PRIu32
	        " pos=%" PRId32 ",%" PRId32 " title=%s\n",
	        window->windowId, window->shown ? 1 : 0, window->remotePublished ? 1 : 0,
	        window->baselineWindow ? 1 : 0, context->railStartSent ? 1 : 0,
	        window->ownerWindowId, window->extendedStyle,
	        context ? context->railActiveWindowId : 0, window->windowWidth, window->windowHeight,
	        window->windowOffsetX,
	        window->windowOffsetY, window->title ? window->title : "");

	if (!publishable)
	{
		if (window->remotePublished)
		{
			winp_remote_window_event(context, 1, window->windowId, window);
			window->remotePublished = FALSE;
		}
		return;
	}

	winp_remote_window_event(context, window->remotePublished ? 2 : 0, window->windowId, window);
	window->remotePublished = TRUE;
}

static void winp_try_activate_first_shown_window(winpContext* context)
{
	winpRailWindowState* cur = NULL;

	if (!context)
		return;

	for (cur = context->railWindows; cur; cur = cur->next)
	{
		if (!cur->shown || cur->activated)
			continue;

		winp_try_activate_rail_window(context, cur->windowId);
		return;
	}
}

static void winp_try_activate_monitored_desktop_window(winpContext* context)
{
	winpRailWindowState* window = NULL;
	UINT32 index = 0;

	if (!context)
		return;

	if ((context->railActiveWindowId != 0) && (context->railActiveWindowId != UINT32_MAX))
	{
		window = winp_find_or_create_rail_window(context, context->railActiveWindowId);
		if (window && window->shown)
		{
			winp_try_activate_rail_window(context, context->railActiveWindowId);
			return;
		}
	}

	for (index = 0; index < context->railDesktopWindowCount; index++)
	{
		const UINT32 windowId = context->railDesktopWindowIds[index];
		window = winp_find_or_create_rail_window(context, windowId);
		if (!window || !window->shown)
			continue;

		winp_try_activate_rail_window(context, windowId);
		return;
	}
}

static void winp_sync_desktop_window_visibility(winpContext* context)
{
	winpRailWindowState* cur = NULL;

	if (!context)
		return;

	for (cur = context->railWindows; cur; cur = cur->next)
	{
		const BOOL inDesktop =
		    winp_window_id_in_list(context->railDesktopWindowIds, context->railDesktopWindowCount,
		                           cur->windowId);
		const BOOL shouldShow = inDesktop && (cur->windowWidth > 0) && (cur->windowHeight > 0) &&
		                        !cur->cloaked;

		if (cur->shown != shouldShow)
		{
			cur->shown = shouldShow;
			if (!shouldShow)
				cur->systemCommandSent = FALSE;
		}

		if (context->railStartSent)
			winp_publish_remote_window_if_needed(context, cur);
	}
}

static void winp_try_activate_latest_new_rail_window(winpContext* context)
{
	winpRailWindowState* cur = NULL;

	if (!context)
		return;

	for (cur = context->railWindows; cur; cur = cur->next)
	{
		if (!cur->shown || cur->activated)
			continue;

		winp_try_activate_rail_window(context, cur->windowId);
		winp_try_send_rail_system_command(context, cur->windowId);
		return;
	}
}

static void winp_try_send_rail_system_command(winpContext* context, UINT32 windowId)
{
	RAIL_SYSCOMMAND_ORDER syscommand = WINPR_C_ARRAY_INIT;
	winpRailWindowState* window = NULL;
	UINT16 command = 0;
	UINT rc = CHANNEL_RC_OK;

	if (!context || !context->railContext)
		return;

	window = winp_find_or_create_rail_window(context, windowId);
	if (!window || window->systemCommandSent || !window->shown)
		return;

	switch (window->showState)
	{
		case WINDOW_SHOW_MINIMIZED:
			command = SC_MINIMIZE;
			break;

		case WINDOW_SHOW_MAXIMIZED:
			command = SC_MAXIMIZE;
			break;

		default:
			return;
	}

	syscommand.windowId = windowId;
	syscommand.command = command;
	rc = context->railContext->ClientSystemCommand(context->railContext, &syscommand);
	fprintf(stderr,
	        "[WinP][rail] system command window id=0x%08" PRIX32 " cmd=0x%04" PRIX16
	        " rc=%" PRIu32 "\n",
	        windowId, command, rc);

	if (rc == CHANNEL_RC_OK)
		window->systemCommandSent = TRUE;
}

static void winp_try_send_first_shown_system_command(winpContext* context)
{
	winpRailWindowState* cur = NULL;

	if (!context)
		return;

	for (cur = context->railWindows; cur; cur = cur->next)
	{
		if (!cur->shown || cur->systemCommandSent)
			continue;

		winp_try_send_rail_system_command(context, cur->windowId);
		return;
	}
}

static BOOL winp_rail_window_common(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                    const WINDOW_STATE_ORDER* windowState)
{
	winpContext* wctx = (winpContext*)context;
	winpRailWindowState* window = NULL;
	fprintf(stderr, "[WinP][rail] window update id=0x%08" PRIX32 " fields=0x%08" PRIX32 "\n",
	        orderInfo ? orderInfo->windowId : 0, orderInfo ? orderInfo->fieldFlags : 0);

	if (wctx && orderInfo)
	{
		const BOOL isNewWindow = ((orderInfo->fieldFlags & WINDOW_ORDER_STATE_NEW) != 0);
		window = winp_find_or_create_rail_window(wctx, orderInfo->windowId);
		if (window && windowState)
		{
			if (!winp_update_rail_window_state(window, orderInfo, windowState))
				return FALSE;

			if (isNewWindow)
			{
				window->baselineWindow = FALSE;
				window->shown = FALSE;
				window->systemCommandSent = FALSE;
				window->appIdRequested = FALSE;
			}
			if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_SHOW) != 0)
			{
				window->shown = (windowState->showState != WINDOW_HIDE);
				window->systemCommandSent = FALSE;
			}
			if ((orderInfo->fieldFlags & WINDOW_ORDER_STATE_DELETED) != 0)
				window->shown = FALSE;
			else
				window->shown = (window->showState != WINDOW_HIDE);

			WINPR_UNUSED(isNewWindow);
			winp_publish_remote_window_if_needed(wctx, window);
			/* Temporarily disable appid request to reduce RAIL protocol surface. */
		}
	}

	return TRUE;
}

static BOOL winp_rail_window_icon(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                  const WINDOW_ICON_ORDER* windowIcon)
{
	WINPR_UNUSED(context);
	WINPR_UNUSED(windowIcon);
	fprintf(stderr, "[WinP][rail] window icon id=0x%08" PRIX32 "\n",
	        orderInfo ? orderInfo->windowId : 0);
	return TRUE;
}

static BOOL winp_rail_window_cached_icon(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                         const WINDOW_CACHED_ICON_ORDER* windowCachedIcon)
{
	WINPR_UNUSED(context);
	WINPR_UNUSED(windowCachedIcon);
	fprintf(stderr, "[WinP][rail] window cached icon id=0x%08" PRIX32 "\n",
	        orderInfo ? orderInfo->windowId : 0);
	return TRUE;
}

static BOOL winp_rail_window_delete(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	winpContext* wctx = (winpContext*)context;
	fprintf(stderr, "[WinP][rail] window delete id=0x%08" PRIX32 "\n",
	        orderInfo ? orderInfo->windowId : 0);
	if (wctx && orderInfo)
		winp_remove_rail_window(wctx, orderInfo->windowId);
	return TRUE;
}

static BOOL winp_rail_notify_icon_create(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                         const NOTIFY_ICON_STATE_ORDER* notifyIconState)
{
	WINPR_UNUSED(context);
	WINPR_UNUSED(notifyIconState);
	fprintf(stderr, "[WinP][rail] notify icon create id=0x%08" PRIX32 "\n",
	        orderInfo ? orderInfo->windowId : 0);
	return TRUE;
}

static BOOL winp_rail_notify_icon_update(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                         const NOTIFY_ICON_STATE_ORDER* notifyIconState)
{
	WINPR_UNUSED(context);
	WINPR_UNUSED(notifyIconState);
	fprintf(stderr, "[WinP][rail] notify icon update id=0x%08" PRIX32 "\n",
	        orderInfo ? orderInfo->windowId : 0);
	return TRUE;
}

static BOOL winp_rail_notify_icon_delete(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	WINPR_UNUSED(context);
	fprintf(stderr, "[WinP][rail] notify icon delete id=0x%08" PRIX32 "\n",
	        orderInfo ? orderInfo->windowId : 0);
	return TRUE;
}

static BOOL winp_rail_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                        const MONITORED_DESKTOP_ORDER* monitoredDesktop)
{
	winpContext* wctx = (winpContext*)context;
	const UINT32 mask = WINDOW_ORDER_TYPE_DESKTOP | WINDOW_ORDER_FIELD_DESKTOP_HOOKED |
	                    WINDOW_ORDER_FIELD_DESKTOP_ARC_BEGAN |
	                    WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED |
	                    WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND |
	                    WINDOW_ORDER_FIELD_DESKTOP_ZORDER;

	WINPR_UNUSED(monitoredDesktop);

	if (!wctx || !orderInfo || !wctx->railContext)
		return TRUE;

	if ((orderInfo->fieldFlags & WINDOW_ORDER_TYPE_DESKTOP) == 0)
		return TRUE;

	/* Match xfreerdp behavior: keep monitored-desktop handling passive.
	 * Window lifecycle is driven by WINDOW_ORDER create/update/delete orders.
	 */
	if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_BEGAN) != 0)
		fprintf(stderr, "[WinP][rail] desktop arc began (passive)\n");
	if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_HOOKED) != 0)
		fprintf(stderr, "[WinP][rail] desktop hooked (passive)\n");
	if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) != 0)
	{
		fprintf(stderr, "[WinP][rail] desktop arc completed (passive)\n");
		wctx->railStartSent = TRUE;
	}
	if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND) != 0)
	{
		if (monitoredDesktop)
			wctx->railActiveWindowId = monitoredDesktop->activeWindowId;
		fprintf(stderr,
		        "[WinP][rail] desktop active window update active=0x%08" PRIX32 " count=%" PRIu32
		        " (passive)\n",
		        monitoredDesktop ? monitoredDesktop->activeWindowId : 0,
		        monitoredDesktop ? monitoredDesktop->numWindowIds : 0);
	}
	if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ZORDER) != 0)
	{
		if (monitoredDesktop)
		{
			(void)winp_copy_window_ids(&wctx->railDesktopWindowIds, &wctx->railDesktopWindowCount,
			                           monitoredDesktop->windowIds, monitoredDesktop->numWindowIds);
		}
		fprintf(stderr, "[WinP][rail] desktop zorder update count=%" PRIu32 " (passive)\n",
		        monitoredDesktop ? monitoredDesktop->numWindowIds : 0);
	}
	if ((orderInfo->fieldFlags & ~mask) != 0)
		fprintf(stderr, "[WinP][rail] desktop unknown flags=0x%08" PRIX32 "\n",
		        orderInfo->fieldFlags & ~mask);

	return TRUE;
}

static BOOL winp_rail_non_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	WINPR_UNUSED(context);
	WINPR_UNUSED(orderInfo);
	return TRUE;
}

static UINT winp_rail_server_handshake(RailClientContext* rail,
                                       const RAIL_HANDSHAKE_ORDER* handshake)
{
	winpContext* wctx = NULL;
	WINPR_UNUSED(handshake);
	fprintf(stderr, "[WinP][rail] server handshake\n");

	if (!rail)
		return CHANNEL_RC_OK;

	wctx = (winpContext*)rail->custom;
	if (!wctx)
		return CHANNEL_RC_OK;

	if (!wctx->railStartupIssued)
	{
		const UINT rc = winp_send_rail_startup_orders(wctx);
		fprintf(stderr, "[WinP][rail] start cmd rc=%" PRIu32 "\n", rc);
		if (rc == CHANNEL_RC_OK)
			wctx->railStartupIssued = TRUE;
		else
			winp_status(wctx, "rail-start-cmd-failed");
	}

	return CHANNEL_RC_OK;
}

static UINT winp_rail_server_handshake_ex(RailClientContext* rail,
                                          const RAIL_HANDSHAKE_EX_ORDER* handshakeEx)
{
	winpContext* wctx = NULL;
	WINPR_UNUSED(handshakeEx);
	fprintf(stderr, "[WinP][rail] server handshake ex\n");

	if (!rail)
		return CHANNEL_RC_OK;

	wctx = (winpContext*)rail->custom;
	if (!wctx)
		return CHANNEL_RC_OK;

	if (!wctx->railStartupIssued)
	{
		const UINT rc = winp_send_rail_startup_orders(wctx);
		fprintf(stderr, "[WinP][rail] start cmd rc=%" PRIu32 "\n", rc);
		if (rc == CHANNEL_RC_OK)
			wctx->railStartupIssued = TRUE;
		else
			winp_status(wctx, "rail-start-cmd-failed");
	}

	return CHANNEL_RC_OK;
}

static void winp_on_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	char buffer[256] = { 0 };
	winpContext* wctx = (winpContext*)context;

	WINPR_ASSERT(context);
	WINPR_ASSERT(e);

	(void)snprintf(buffer, sizeof(buffer), "channel-connected:%s", e->name ? e->name : "unknown");
	winp_status(wctx, buffer);

	if ((strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0) && e->pInterface)
	{
		RailClientContext* rail = (RailClientContext*)e->pInterface;
		rdpWindowUpdate* window = NULL;
		rail->custom = wctx;
		rail->ServerExecuteResult = winp_rail_server_execute_result;
		rail->ServerSystemParam = winp_rail_server_system_param;
		rail->ServerHandshake = winp_rail_server_handshake;
		rail->ServerHandshakeEx = winp_rail_server_handshake_ex;
		rail->ServerLocalMoveSize = winp_rail_server_local_move_size;
		rail->ServerMinMaxInfo = winp_rail_server_min_max_info;
		rail->ServerLanguageBarInfo = winp_rail_server_language_bar_info;
		rail->ServerGetAppIdResponse = winp_rail_server_get_appid_response;
		rail->ServerTaskBarInfo = winp_rail_server_taskbar_info;
		rail->ServerZOrderSync = winp_rail_server_zorder_sync;
		rail->ServerCloak = winp_rail_server_cloak;
		rail->ServerPowerDisplayRequest = winp_rail_server_power_display_request;
		rail->ServerGetAppidResponseExtended = winp_rail_server_get_appid_response_ex;
		wctx->railContext = rail;
		wctx->railStartSent = FALSE;
		wctx->railStartupIssued = FALSE;
		if (wctx->context.update && wctx->context.update->window)
		{
			window = wctx->context.update->window;
			window->WindowCreate = winp_rail_window_common;
			window->WindowUpdate = winp_rail_window_common;
			window->WindowIcon = winp_rail_window_icon;
			window->WindowCachedIcon = winp_rail_window_cached_icon;
			window->WindowDelete = winp_rail_window_delete;
			window->NotifyIconCreate = winp_rail_notify_icon_create;
			window->NotifyIconUpdate = winp_rail_notify_icon_update;
			window->NotifyIconDelete = winp_rail_notify_icon_delete;
			window->MonitoredDesktop = winp_rail_monitored_desktop;
			window->NonMonitoredDesktop = winp_rail_non_monitored_desktop;
		}
		fprintf(stderr, "[WinP][rail] client context initialized\n");
	}
}

static void winp_on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	char buffer[256] = { 0 };
	winpContext* wctx = (winpContext*)context;

	WINPR_ASSERT(context);
	WINPR_ASSERT(e);

	(void)snprintf(buffer, sizeof(buffer), "channel-disconnected:%s",
	               e->name ? e->name : "unknown");
	winp_status(wctx, buffer);

	if ((strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0) && wctx)
	{
		wctx->railContext = NULL;
		wctx->railStartSent = FALSE;
		wctx->railStartupIssued = FALSE;
		winp_clear_rail_windows(wctx);
		winp_clear_rail_desktop_state(wctx);
	}
}

static void winp_cursor(winpContext* context, int kind, const BYTE* data, UINT32 width,
	                    UINT32 height, UINT32 hotspotX, UINT32 hotspotY)
{
	if (context && context->cursorCallback)
	{
		context->cursorCallback(kind, data, (int)width, (int)height, (int)hotspotX,
		                        (int)hotspotY, context->userData);
	}
}

static BOOL winp_pointer_new(rdpContext* context, rdpPointer* pointer)
{
	UINT32 width = 0;
	UINT32 height = 0;
	UINT32 length = 0;
	BYTE* dst = NULL;
	winpPointer* winpPointerData = NULL;
	const gdiPalette* palette = NULL;

	if (!context || !pointer || !context->gdi)
		return FALSE;

	width = pointer->width;
	height = pointer->height;
	if ((width == 0) || (height == 0))
		return FALSE;

	length = width * height * 4;
	dst = (BYTE*)calloc(length, sizeof(BYTE));
	if (!dst)
		return FALSE;

	if (context->gdi)
		palette = &context->gdi->palette;

	if (!freerdp_image_copy_from_pointer_data(
	        dst, PIXEL_FORMAT_BGRA32, 0, 0, 0, width, height, pointer->xorMaskData,
	        pointer->lengthXorMask, pointer->andMaskData, pointer->lengthAndMask, pointer->xorBpp,
	        palette))
	{
		free(dst);
		return FALSE;
	}

	winpPointerData = (winpPointer*)pointer;
	free(winpPointerData->imageData);
	winpPointerData->imageData = dst;
	winpPointerData->imageLength = length;
	return TRUE;
}

static void winp_pointer_free(WINPR_ATTR_UNUSED rdpContext* context, rdpPointer* pointer)
{
	winpPointer* winpPointerData = NULL;

	if (!pointer)
		return;

	winpPointerData = (winpPointer*)pointer;
	free(winpPointerData->imageData);
	winpPointerData->imageData = NULL;
	winpPointerData->imageLength = 0;
}

static BOOL winp_pointer_set(rdpContext* context, rdpPointer* pointer)
{
	winpContext* wctx = NULL;
	winpPointer* winpPointerData = NULL;

	if (!context || !pointer)
		return FALSE;

	wctx = (winpContext*)context;
	winpPointerData = (winpPointer*)pointer;

	if (winpPointerData->imageData && (winpPointerData->imageLength > 0))
	{
		winp_cursor(wctx, WINP_CURSOR_KIND_CUSTOM, winpPointerData->imageData, pointer->width,
		            pointer->height, pointer->xPos, pointer->yPos);
	}

	return TRUE;
}

static BOOL winp_pointer_set_null(rdpContext* context)
{
	if (!context)
		return FALSE;

	winp_cursor((winpContext*)context, WINP_CURSOR_KIND_HIDDEN, NULL, 0, 0, 0, 0);
	return TRUE;
}

static BOOL winp_pointer_set_default(rdpContext* context)
{
	if (!context)
		return FALSE;

	winp_cursor((winpContext*)context, WINP_CURSOR_KIND_DEFAULT, NULL, 0, 0, 0, 0);
	return TRUE;
}

static BOOL winp_pointer_set_position(WINPR_ATTR_UNUSED rdpContext* context,
	                                  WINPR_ATTR_UNUSED UINT32 x,
	                                  WINPR_ATTR_UNUSED UINT32 y)
{
	return TRUE;
}

static BOOL winp_begin_paint(rdpContext* context)
{
	rdpGdi* gdi = NULL;

	WINPR_ASSERT(context);
	gdi = context->gdi;
	WINPR_ASSERT(gdi);
	WINPR_ASSERT(gdi->primary);
	WINPR_ASSERT(gdi->primary->hdc);
	WINPR_ASSERT(gdi->primary->hdc->hwnd);
	WINPR_ASSERT(gdi->primary->hdc->hwnd->invalid);
	gdi->primary->hdc->hwnd->invalid->null = TRUE;
	return TRUE;
}

static BOOL winp_end_paint(rdpContext* context)
{
	rdpGdi* gdi = NULL;
	winpContext* wctx = NULL;
	HGDI_DC hdc = NULL;
	HGDI_WND hwnd = NULL;

	WINPR_ASSERT(context);
	gdi = context->gdi;
	WINPR_ASSERT(gdi);
	WINPR_ASSERT(gdi->primary);

	hdc = gdi->primary->hdc;
	if (!hdc || !hdc->hwnd)
		return TRUE;

	hwnd = hdc->hwnd;
	if (!hwnd->invalid || hwnd->invalid->null)
		return TRUE;

	wctx = (winpContext*)context;
	if (wctx->frameCallback && gdi->primary_buffer)
	{
		wctx->frameCallback(gdi->primary_buffer, gdi->width, gdi->height, (int)gdi->stride,
		                   wctx->userData);
	}

	return TRUE;
}

static BOOL winp_desktop_resize(rdpContext* context)
{
	rdpGdi* gdi = NULL;
	rdpSettings* settings = NULL;

	WINPR_ASSERT(context);
	settings = context->settings;
	gdi = context->gdi;
	if (!gdi || !settings)
		return FALSE;

	return gdi_resize(gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
	                  freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
}

static BOOL winp_pre_connect(freerdp* instance)
{
	WINPR_ASSERT(instance);

	if (!instance->context || !instance->context->pubSub)
		return FALSE;

	if (PubSub_SubscribeChannelConnected(instance->context->pubSub,
	                                     winp_on_channel_connected) < 0)
	{
		return FALSE;
	}

	if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub,
	                                        winp_on_channel_disconnected) < 0)
	{
		return FALSE;
	}

	return TRUE;
}

static BOOL winp_post_connect(freerdp* instance)
{
	rdpContext* context = NULL;
	winpContext* wctx = NULL;
	rdpPointer pointer = WINPR_C_ARRAY_INIT;

	if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
		return FALSE;

	context = instance->context;
	WINPR_ASSERT(context);
	WINPR_ASSERT(context->update);

	context->update->BeginPaint = winp_begin_paint;
	context->update->EndPaint = winp_end_paint;
	context->update->DesktopResize = winp_desktop_resize;

	pointer.size = sizeof(winpPointer);
	pointer.New = winp_pointer_new;
	pointer.Free = winp_pointer_free;
	pointer.Set = winp_pointer_set;
	pointer.SetNull = winp_pointer_set_null;
	pointer.SetDefault = winp_pointer_set_default;
	pointer.SetPosition = winp_pointer_set_position;
	graphics_register_pointer(context->graphics, &pointer);

	wctx = (winpContext*)context;
	winp_status(wctx, "connected");
	winp_cursor(wctx, WINP_CURSOR_KIND_DEFAULT, NULL, 0, 0, 0, 0);
	return TRUE;
}

static void winp_post_disconnect(freerdp* instance)
{
	UINT32 errorCode = FREERDP_ERROR_SUCCESS;
	int disconnectReason = 0;
	const char* errorString = NULL;
	const char* reasonString = NULL;

	if (!instance || !instance->context)
		return;

	errorCode = freerdp_get_last_error(instance->context);
	disconnectReason = freerdp_get_disconnect_ultimatum(instance->context);
	errorString = freerdp_get_last_error_string(errorCode);
	reasonString = freerdp_disconnect_reason_string(disconnectReason);

	fprintf(stderr,
	        "[WinP] post-disconnect last_error=0x%08" PRIX32 " (%s) disconnect_reason=0x%08X (%s)\n",
	        errorCode, errorString ? errorString : "unknown", (unsigned int)disconnectReason,
	        reasonString ? reasonString : "none");

	winp_status((winpContext*)instance->context, "disconnected");
	gdi_free(instance);
}

static BOOL winp_send_resolution_update(freerdp* instance, int width, int height)
{
	rdpSettings* settings = NULL;
	MONITOR_DEF monitor = { 0 };

	if (!instance || !instance->context)
		return FALSE;

	if ((width < 200) || (height < 200))
		return FALSE;

	settings = instance->context->settings;
	if (!settings)
		return FALSE;

	/* RemoteApp sessions are window-based; monitor layout updates can destabilize
	 * some servers/proxies and are not required for this mode.
	 */
	if (freerdp_settings_get_bool(settings, FreeRDP_RemoteApplicationMode))
		return TRUE;

	monitor.left = 0;
	monitor.top = 0;
	monitor.right = width - 1;
	monitor.bottom = height - 1;
	monitor.flags = MONITOR_PRIMARY;

	if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, (UINT32)width) ||
	    !freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, (UINT32)height))
	{
		return FALSE;
	}

	return freerdp_display_send_monitor_layout(instance->context, 1, &monitor);
}

static DWORD winp_loop(freerdp* instance)
{
	DWORD nCount = 0;
	HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
	BOOL remoteAppResizeSuppressedLogged = FALSE;

	while (!g_session.stopRequested && !freerdp_shall_disconnect_context(instance->context))
	{
		BOOL hasPendingResize = FALSE;
		int resizeWidth = 0;
		int resizeHeight = 0;

		(void)pthread_mutex_lock(&g_session.lock);
		hasPendingResize = g_session.pendingResize;
		resizeWidth = g_session.pendingWidth;
		resizeHeight = g_session.pendingHeight;
		g_session.pendingResize = FALSE;
		(void)pthread_mutex_unlock(&g_session.lock);

		if (hasPendingResize)
		{
			const rdpSettings* settings = instance->context ? instance->context->settings : NULL;
			const BOOL remoteAppMode =
			    settings ? freerdp_settings_get_bool(settings, FreeRDP_RemoteApplicationMode)
			             : FALSE;

			if (remoteAppMode)
			{
				if (!remoteAppResizeSuppressedLogged)
				{
					fprintf(stderr,
					        "[WinP] remoteapp mode: suppress all resolution update requests\n");
					remoteAppResizeSuppressedLogged = TRUE;
				}
			}
			else if (!winp_send_resolution_update(instance, resizeWidth, resizeHeight))
			{
				fprintf(stderr, "[WinP] dynamic resolution update failed (%dx%d)\n", resizeWidth,
				        resizeHeight);
			}
		}

		nCount = freerdp_get_event_handles(instance->context, handles, ARRAYSIZE(handles));
		if (nCount == 0)
			return 1;

		const DWORD status = WaitForMultipleObjects(nCount, handles, FALSE, 50);
		if (status == WAIT_FAILED)
			return 2;

		if (!freerdp_check_event_handles(instance->context))
			return 3;
	}

	return 0;
}

static void* winp_session_thread(void* arg)
{
	freerdp* instance = (freerdp*)arg;
	DWORD loopResult = 0;

	if (!freerdp_connect(instance))
	{
		UINT32 errorCode = freerdp_get_last_error(instance->context);
		const char* errorString = freerdp_get_last_error_string(errorCode);
		if (errorString)
			(void)snprintf(g_session.errorText, sizeof(g_session.errorText), "%s", errorString);
		else
			(void)snprintf(g_session.errorText, sizeof(g_session.errorText), "%s", "connect failed");
		goto cleanup;
	}

	loopResult = winp_loop(instance);
	if (loopResult != 0)
	{
		(void)snprintf(g_session.errorText, sizeof(g_session.errorText), "event loop failed: %u",
		               loopResult);
	}

cleanup:
	if (instance)
	{
		(void)freerdp_disconnect(instance);
	}

	g_session.running = FALSE;
	return NULL;
}

static BOOL winp_configure_instance(freerdp* instance, const char* host, const char* username,
		                                 const char* password, const char* domain, int width,
		                                 int height, int fullscreen,
		                                 winp_frame_callback_t frameCallback,
		                                 winp_cursor_callback_t cursorCallback,
		                                 winp_status_callback_t statusCallback, void* userData,
		                                 char* errorOut, size_t errorOutSize)
{
	rdpSettings* settings = NULL;
	winpContext* context = NULL;

	instance->ContextSize = sizeof(winpContext);
	instance->PreConnect = winp_pre_connect;
	instance->PostConnect = winp_post_connect;
	instance->PostDisconnect = winp_post_disconnect;
	instance->LoadChannels = freerdp_client_load_channels;

	if (!freerdp_context_new(instance))
	{
		winp_set_error(errorOut, errorOutSize, "freerdp_context_new failed");
		return FALSE;
	}

	context = (winpContext*)instance->context;
	context->frameCallback = frameCallback;
	context->cursorCallback = cursorCallback;
	context->remoteWindowCallback = NULL;
	context->statusCallback = statusCallback;
	context->userData = userData;

	settings = instance->context->settings;
	if (!settings)
	{
		winp_set_error(errorOut, errorOutSize, "settings unavailable");
		return FALSE;
	}

	(void)WLog_SetStringLogLevel(WLog_GetRoot(), "DEBUG");
	(void)WLog_SetStringLogLevel(WLog_Get("com.freerdp.channels.rdpsnd.client"), "DEBUG");
	(void)WLog_SetStringLogLevel(WLog_Get("com.freerdp.channels.rdpdr.client"), "DEBUG");
	(void)WLog_SetStringLogLevel(WLog_Get("com.freerdp.channels.drdynvc.client"), "DEBUG");
	(void)WLog_SetStringLogLevel(WLog_Get("com.freerdp.channels.cliprdr.client"), "DEBUG");

	if (!winp_set_setting(settings, "FreeRDP_ServerHostname", host) ||
	    !winp_set_setting(settings, "FreeRDP_Username", username) ||
	    !winp_set_setting(settings, "FreeRDP_Password", password) ||
	    !winp_set_setting(settings, "FreeRDP_IgnoreCertificate", "true") ||
	    !winp_set_setting(settings, "FreeRDP_SupportDisplayControl",
	                      winp_env_true("WINP_MIN_CHANNELS") ? "false" : "true") ||
	    !winp_set_setting(settings, "FreeRDP_DynamicResolutionUpdate", "true"))
	{
		winp_set_error(errorOut, errorOutSize, "failed to set connection settings");
		return FALSE;
	}

	if (domain && (strlen(domain) > 0) &&
	    !winp_set_setting(settings, "FreeRDP_Domain", domain))
	{
		winp_set_error(errorOut, errorOutSize, "failed to set domain");
		return FALSE;
	}

	g_minimalChannelMode = winp_env_true("WINP_MIN_CHANNELS");
	fprintf(stderr, "[WinP] build=%s %s\n", __DATE__, __TIME__);
	fprintf(stderr, "[WinP] channel mode: minimal=%d\n", g_minimalChannelMode ? 1 : 0);

	if (!winp_enable_audio_addins(instance->context, errorOut, errorOutSize))
		return FALSE;

	if (fullscreen)
	{
		if (!winp_set_setting(settings, "FreeRDP_Fullscreen", "true"))
		{
			winp_set_error(errorOut, errorOutSize, "failed to set fullscreen");
			return FALSE;
		}
	}
	else
	{
		char widthText[32] = { 0 };
		char heightText[32] = { 0 };
		(void)snprintf(widthText, sizeof(widthText), "%d", width);
		(void)snprintf(heightText, sizeof(heightText), "%d", height);

		if (!winp_set_setting(settings, "FreeRDP_DesktopWidth", widthText) ||
		    !winp_set_setting(settings, "FreeRDP_DesktopHeight", heightText))
		{
			winp_set_error(errorOut, errorOutSize, "failed to set desktop size");
			return FALSE;
		}
	}

	return TRUE;
}

const char* winp_freerdp_version_string(void)
{
	const char* version = freerdp_get_version_string();
	if (version == NULL)
		return "unknown";
	return version;
}

int winp_freerdp_connect_test(const char* host, const char* username, const char* password,
	                          const char* domain, char* errorOut, size_t errorOutSize)
{
	int rc = 1;
	freerdp* instance = NULL;
	rdpSettings* settings = NULL;

	winp_set_error(errorOut, errorOutSize, "");

	if (!host || !username || !password)
	{
		winp_set_error(errorOut, errorOutSize, "invalid arguments");
		return 2;
	}

	instance = freerdp_new();
	if (!instance)
	{
		winp_set_error(errorOut, errorOutSize, "freerdp_new failed");
		return 3;
	}

	if (!freerdp_context_new(instance))
	{
		winp_set_error(errorOut, errorOutSize, "freerdp_context_new failed");
		goto cleanup;
	}

	settings = instance->context->settings;
	if (!settings)
	{
		winp_set_error(errorOut, errorOutSize, "settings unavailable");
		goto cleanup;
	}

	if (!winp_set_setting(settings, "FreeRDP_ServerHostname", host) ||
	    !winp_set_setting(settings, "FreeRDP_Username", username) ||
	    !winp_set_setting(settings, "FreeRDP_Password", password) ||
	    !winp_set_setting(settings, "FreeRDP_IgnoreCertificate", "true"))
	{
		winp_set_error(errorOut, errorOutSize, "failed to set connection settings");
		goto cleanup;
	}

	if (domain && (strlen(domain) > 0))
	{
		if (!winp_set_setting(settings, "FreeRDP_Domain", domain))
		{
			winp_set_error(errorOut, errorOutSize, "failed to set domain");
			goto cleanup;
		}
	}

	if (!freerdp_connect(instance))
	{
		UINT32 errorCode = freerdp_get_last_error(instance->context);
		int disconnectReason = freerdp_get_disconnect_ultimatum(instance->context);
		const char* errorString = freerdp_get_last_error_string(errorCode);

		if (disconnectReason != 0)
		{
			const char* reason = freerdp_disconnect_reason_string(disconnectReason);
			if (reason)
				winp_set_error(errorOut, errorOutSize, reason);
			else
				winp_set_error(errorOut, errorOutSize, "disconnect reason available but unknown");
		}
		else if (errorString && (errorCode != FREERDP_ERROR_SUCCESS))
			winp_set_error(errorOut, errorOutSize, errorString);
		else
			winp_set_error(errorOut, errorOutSize,
			               "freerdp_connect failed (no explicit last_error; check credentials/domain)");
		goto cleanup;
	}

	(void)freerdp_disconnect(instance);
	rc = 0;

cleanup:
	if (instance)
	{
		freerdp_context_free(instance);
		freerdp_free(instance);
	}

	return rc;
}

int winp_freerdp_start_session(const char* host, const char* username, const char* password,
	                               const char* domain, int width, int height, int fullscreen,
	                               winp_frame_callback_t frameCallback,
	                               winp_cursor_callback_t cursorCallback,
	                               winp_status_callback_t statusCallback, void* userData,
	                               char* errorOut, size_t errorOutSize)
{
	freerdp* instance = NULL;

	winp_set_error(errorOut, errorOutSize, "");
	if (!host || !username || !password)
	{
		winp_set_error(errorOut, errorOutSize, "invalid arguments");
		return 2;
	}

	winp_freerdp_stop_session();

	instance = freerdp_new();
	if (!instance)
	{
		winp_set_error(errorOut, errorOutSize, "freerdp_new failed");
		return 3;
	}

	if (!winp_configure_instance(instance, host, username, password, domain, width, height,
	                            fullscreen, frameCallback, cursorCallback, statusCallback, userData,
	                            errorOut, errorOutSize))
	{
		freerdp_context_free(instance);
		freerdp_free(instance);
		return 4;
	}

	g_session.instance = instance;
	g_session.stopRequested = FALSE;
	g_session.pendingResize = FALSE;
	g_session.pendingWidth = 0;
	g_session.pendingHeight = 0;
	g_session.running = TRUE;
	g_session.errorText[0] = '\0';

	if (pthread_create(&g_session.thread, NULL, winp_session_thread, instance) != 0)
	{
		g_session.running = FALSE;
		winp_set_error(errorOut, errorOutSize, "failed to create session thread");
		freerdp_context_free(instance);
		freerdp_free(instance);
		g_session.instance = NULL;
		return 5;
	}

	return 0;
}

int winp_freerdp_update_resolution(int width, int height, char* errorOut, size_t errorOutSize)
{
	winp_set_error(errorOut, errorOutSize, "");

	if ((width < 200) || (height < 200))
	{
		winp_set_error(errorOut, errorOutSize, "invalid resolution");
		return 2;
	}

	if (!g_session.running || !g_session.instance || !g_session.instance->context)
	{
		winp_set_error(errorOut, errorOutSize, "session is not running");
		return 3;
	}

	(void)pthread_mutex_lock(&g_session.lock);
	g_session.pendingWidth = width;
	g_session.pendingHeight = height;
	g_session.pendingResize = TRUE;
	(void)pthread_mutex_unlock(&g_session.lock);

	return 0;
}

int winp_freerdp_send_mouse_event(uint16_t flags, uint16_t x, uint16_t y, char* errorOut,
							  size_t errorOutSize)
{
	rdpInput* input = NULL;

	winp_set_error(errorOut, errorOutSize, "");

	if (!g_session.running || !g_session.instance || !g_session.instance->context ||
	    !g_session.instance->context->input)
	{
		winp_set_error(errorOut, errorOutSize, "session/input not ready");
		return 2;
	}

	input = g_session.instance->context->input;

	if (!freerdp_input_send_mouse_event(input, flags, x, y))
	{
		winp_set_error(errorOut, errorOutSize, "freerdp_input_send_mouse_event failed");
		return 3;
	}

	return 0;
}

int winp_freerdp_send_unicode_key(int down, uint16_t code, char* errorOut, size_t errorOutSize)
{
	UINT16 flags = 0;
	rdpInput* input = NULL;

	winp_set_error(errorOut, errorOutSize, "");

	if (!g_session.running || !g_session.instance || !g_session.instance->context ||
	    !g_session.instance->context->input)
	{
		winp_set_error(errorOut, errorOutSize, "session/input not ready");
		return 2;
	}

	input = g_session.instance->context->input;

	if (!down)
		flags |= KBD_FLAGS_RELEASE;

	if (!freerdp_input_send_unicode_keyboard_event(input, flags, code))
	{
		winp_set_error(errorOut, errorOutSize, "freerdp_input_send_unicode_keyboard_event failed");
		return 3;
	}

	return 0;
}

int winp_freerdp_send_scancode_key(int down, uint32_t scancode, char* errorOut,
							   size_t errorOutSize)
{
	rdpInput* input = NULL;

	winp_set_error(errorOut, errorOutSize, "");

	if (!g_session.running || !g_session.instance || !g_session.instance->context ||
	    !g_session.instance->context->input)
	{
		winp_set_error(errorOut, errorOutSize, "session/input not ready");
		return 2;
	}

	input = g_session.instance->context->input;

	if (!freerdp_input_send_keyboard_event_ex(input, down ? TRUE : FALSE, FALSE, scancode))
	{
		winp_set_error(errorOut, errorOutSize, "freerdp_input_send_keyboard_event_ex failed");
		return 3;
	}

	return 0;
}

void winp_freerdp_stop_session(void)
{
	if (!g_session.instance)
		return;

	g_session.stopRequested = TRUE;
	if (g_session.instance->context)
		(void)freerdp_abort_connect_context(g_session.instance->context);

	if (g_session.running)
		(void)pthread_join(g_session.thread, NULL);

	freerdp_context_free(g_session.instance);
	freerdp_free(g_session.instance);
	g_session.instance = NULL;
	g_session.running = FALSE;
	g_session.stopRequested = FALSE;
	g_session.pendingResize = FALSE;
	g_session.pendingWidth = 0;
	g_session.pendingHeight = 0;
	g_session.errorText[0] = '\0';
}
