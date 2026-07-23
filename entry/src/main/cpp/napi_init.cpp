/*******************************************************************************
 *                                                                             *
 *  Copyright (C) 2026 by Max Lv <max.c.lv@gmail.com>                          *
 *                                                                             *
 *  This program is free software: you can redistribute it and/or modify       *
 *  it under the terms of the GNU General Public License as published by       *
 *  the Free Software Foundation, either version 3 of the License, or          *
 *  (at your option) any later version.                                        *
 *                                                                             *
 *  This program is distributed in the hope that it will be useful,            *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of             *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *
 *  GNU General Public License for more details.                               *
 *                                                                             *
 *  You should have received a copy of the GNU General Public License          *
 *  along with this program. If not, see <http://www.gnu.org/licenses/>.       *
 *                                                                             *
 *******************************************************************************/

// NAPI bridge between ArkTS and the Rust sslocal core (libsslocal_core.a).

#include "napi/native_api.h"

#include <string>
#include <vector>

extern "C" {
int sslocal_start(const char *config_json);
int sslocal_start_tun_fd(const char *config_json, int tun_fd);
int sslocal_set_stat_address(const char *addr);
int sslocal_stop();
int sslocal_is_running();
const char *sslocal_last_error();
const char *sslocal_version();
}

namespace {

std::string GetStringArg(napi_env env, napi_value value) {
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string config = GetStringArg(env, args[0]);
    napi_value result;
    napi_create_int32(env, sslocal_start(config.c_str()), &result);
    return result;
}

napi_value StartTunFd(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string config = GetStringArg(env, args[0]);
    int32_t tun_fd = -1;
    napi_get_value_int32(env, args[1], &tun_fd);
    napi_value result;
    napi_create_int32(env, sslocal_start_tun_fd(config.c_str(), tun_fd), &result);
    return result;
}

napi_value SetStatAddress(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string addr = GetStringArg(env, args[0]);
    napi_value result;
    napi_create_int32(env, sslocal_set_stat_address(addr.c_str()), &result);
    return result;
}

napi_value Stop(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, sslocal_stop(), &result);
    return result;
}

napi_value IsRunning(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, sslocal_is_running() != 0, &result);
    return result;
}

napi_value LastError(napi_env env, napi_callback_info info) {
    const char *message = sslocal_last_error();
    napi_value result;
    if (message == nullptr) {
        napi_get_null(env, &result);
    } else {
        napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    }
    return result;
}

napi_value Version(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_string_utf8(env, sslocal_version(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startTunFd", nullptr, StartTunFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setStatAddress", nullptr, SetStatAddress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, LastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module sslocalModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "sslocal",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterSslocalModule() {
    napi_module_register(&sslocalModule);
}
