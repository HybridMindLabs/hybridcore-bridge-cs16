/**
 * HybridCore — Game-Server Bridge (Counter-Strike 1.6 / AMX Mod X)
 *
 * Polls the HybridCore site for queued commands (vote rewards, store
 * purchases, giveaway prizes, bans, …) and executes them in-game, then
 * acknowledges the ones it ran so the site marks them delivered.
 *
 * Protocol (all authenticated with the per-server bearer token "hcb_..."):
 *   POST {base}/api/bridge/poll  -> { "commands": [ { "id": 12, "command": "..." } ] }
 *   POST {base}/api/bridge/ack   <- { "ids": [ 12, 13 ] }
 *
 * Requirements: EasyHTTP (ezhttp) module + AMXX JSON natives (json).
 *
 * Author:  HybridMind Labs
 * License: Proprietary
 */

#include <amxmodx>
#include <amxmisc>
#include <easy_http>
#include <json>

#define PLUGIN  "HybridCore Bridge"
#define VERSION "1.0.0"
#define AUTHOR  "HybridMind Labs"

// Site route paths (appended to the base URL).
#define PATH_POLL "/api/bridge/poll"
#define PATH_ACK  "/api/bridge/ack"

// Max command ids we can ack in one batch — matches the core PULL_LIMIT (25).
#define MAX_BATCH 25

enum _:Cvars {
    CVAR_BASE_URL,
    CVAR_TOKEN,
    CVAR_INTERVAL,
    CVAR_DEBUG,
}
new g_cvar[Cvars];

new g_szBaseUrl[192];
new g_szToken[96];
new g_szAuthHeader[112];
new bool:g_bConfigured = false;

new g_szResponseFile[64];

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR);

    g_cvar[CVAR_BASE_URL] = create_cvar("hc_base_url", "https://your-community.com", FCVAR_PROTECTED,
        "HybridCore site base URL (no trailing slash).");
    g_cvar[CVAR_TOKEN]    = create_cvar("hc_bridge_token", "none", FCVAR_PROTECTED,
        "Per-server bridge token (starts with hcb_). Generate it in Admin -> Servers.");
    g_cvar[CVAR_INTERVAL] = create_cvar("hc_bridge_interval", "5.0", FCVAR_PROTECTED,
        "How often (seconds) to poll for commands.");
    g_cvar[CVAR_DEBUG]    = create_cvar("hc_bridge_debug", "0", FCVAR_PROTECTED,
        "1 = print debug output to the server console.");

    // Manual poll for testing: rcon "hc_bridge_poll"
    register_concmd("hc_bridge_poll", "CmdForcePoll", ADMIN_RCON, "Force a bridge poll now.");

    // Per-server response cache file (unique-ish across map/instances).
    formatex(g_szResponseFile, charsmax(g_szResponseFile), "addons/amxmodx/data/hc_bridge_%d.json", get_systime());

    // Generates & execs addons/amxmodx/configs/hybridcore/config.cfg
    AutoExecConfig(true, "config", "hybridcore");
}

public OnConfigsExecuted()
{
    ReadConfig();

    if (!g_bConfigured) {
        return;
    }

    new Float:interval = get_pcvar_float(g_cvar[CVAR_INTERVAL]);
    if (interval < 2.0) interval = 2.0; // don't hammer the API

    set_task(interval, "TaskPoll", 8371, _, _, "b");

    Debug("Configured. Polling %s every %.1fs", g_szBaseUrl, interval);
}

ReadConfig()
{
    get_pcvar_string(g_cvar[CVAR_BASE_URL], g_szBaseUrl, charsmax(g_szBaseUrl));
    get_pcvar_string(g_cvar[CVAR_TOKEN], g_szToken, charsmax(g_szToken));

    // Trim a trailing slash from the base URL.
    new len = strlen(g_szBaseUrl);
    if (len > 0 && g_szBaseUrl[len - 1] == '/') {
        g_szBaseUrl[len - 1] = EOS;
    }

    g_bConfigured = (strlen(g_szToken) > 4 && equal(g_szToken, "hcb_", 4));

    if (!g_bConfigured) {
        log_amx("[HybridCore] Bridge disabled: set a valid hc_bridge_token (starts with hcb_).");
        return;
    }

    formatex(g_szAuthHeader, charsmax(g_szAuthHeader), "Bearer %s", g_szToken);
}

public CmdForcePoll(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) {
        return PLUGIN_HANDLED;
    }

    if (!g_bConfigured) {
        console_print(id, "[HybridCore] Not configured — set hc_bridge_token first.");
        return PLUGIN_HANDLED;
    }

    TaskPoll();
    console_print(id, "[HybridCore] Poll requested.");
    return PLUGIN_HANDLED;
}

public TaskPoll()
{
    if (!g_bConfigured) {
        return;
    }

    new url[256];
    formatex(url, charsmax(url), "%s%s", g_szBaseUrl, PATH_POLL);

    new EzHttpOptions:opt = ezhttp_create_options();
    ezhttp_option_set_header(opt, "Authorization", g_szAuthHeader);
    ezhttp_option_set_header(opt, "Accept", "application/json");
    ezhttp_option_set_header(opt, "X-Requested-With", "XMLHttpRequest");

    ezhttp_post(url, "OnPollResponse", opt);
}

public OnPollResponse(EzHttpRequest:request_id)
{
    if (ezhttp_get_error_code(request_id) != EZH_OK) {
        new err[128];
        ezhttp_get_error_message(request_id, err, charsmax(err));
        Debug("Poll transport error: %s", err);
        return;
    }

    new http = ezhttp_get_http_code(request_id);
    if (http == 401) {
        log_amx("[HybridCore] Bridge token rejected (401). Check hc_bridge_token.");
        return;
    }
    if (http != 200) {
        Debug("Poll HTTP %d", http);
        return;
    }

    if (!ezhttp_save_data_to_file(request_id, g_szResponseFile)) {
        Debug("Could not save poll response.");
        return;
    }

    ProcessCommands();
}

ProcessCommands()
{
    new JSON:root = json_parse(g_szResponseFile, true);
    if (root == Invalid_JSON) {
        Debug("Invalid JSON in poll response.");
        return;
    }

    new JSON:commands = json_object_get_value(root, "commands");
    if (commands == Invalid_JSON || !json_is_array(commands)) {
        json_free(root);
        delete_file(g_szResponseFile);
        return;
    }

    new count = json_array_get_count(commands);
    if (count <= 0) {
        json_free(commands);
        json_free(root);
        delete_file(g_szResponseFile);
        return;
    }

    new ids[MAX_BATCH];
    new idCount = 0;

    for (new i = 0; i < count && idCount < MAX_BATCH; i++) {
        new JSON:item = json_array_get_value(commands, i);
        if (item == Invalid_JSON) {
            continue;
        }

        new id = json_object_get_number(item, "id");
        new command[256];
        json_object_get_string(item, "command", command, charsmax(command));

        if (id > 0 && strlen(command) > 0) {
            server_cmd("%s", command);
            ids[idCount++] = id;
            Debug("Exec #%d: %s", id, command);
        }

        json_free(item);
    }

    json_free(commands);
    json_free(root);
    delete_file(g_szResponseFile);

    // Flush the queued server commands, then confirm them.
    server_exec();

    if (idCount > 0) {
        SendAck(ids, idCount);
        log_amx("[HybridCore] Executed %d command(s).", idCount);
    }
}

SendAck(const ids[], count)
{
    // Build { "ids": [ 12, 13, 14 ] }
    new body[512];
    new len = copy(body, charsmax(body), "{^"ids^":[");

    for (new i = 0; i < count; i++) {
        len += formatex(body[len], charsmax(body) - len, "%s%d", (i == 0) ? "" : ",", ids[i]);
    }
    copy(body[len], charsmax(body) - len, "]}");

    new url[256];
    formatex(url, charsmax(url), "%s%s", g_szBaseUrl, PATH_ACK);

    new EzHttpOptions:opt = ezhttp_create_options();
    ezhttp_option_set_header(opt, "Authorization", g_szAuthHeader);
    ezhttp_option_set_header(opt, "Content-Type", "application/json");
    ezhttp_option_set_header(opt, "Accept", "application/json");
    ezhttp_option_set_body(opt, body);

    ezhttp_post(url, "OnAckResponse", opt);
}

public OnAckResponse(EzHttpRequest:request_id)
{
    if (ezhttp_get_error_code(request_id) != EZH_OK) {
        Debug("Ack transport error.");
        return;
    }

    Debug("Ack HTTP %d", ezhttp_get_http_code(request_id));
}

Debug(const fmt[], any:...)
{
    if (!get_pcvar_num(g_cvar[CVAR_DEBUG])) {
        return;
    }

    new msg[256];
    vformat(msg, charsmax(msg), fmt, 2);
    server_print("[HybridCore] %s", msg);
}
