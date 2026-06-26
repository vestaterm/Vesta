#ifndef VESTA_LUA_SHIM_H
#define VESTA_LUA_SHIM_H
#include "lua.h"
// The Lua C API exposes these as macros; Swift can't import C macros, so wrap them.
int vesta_lua_registryindex(void);
int vesta_lua_tfunction(void);
int vesta_lua_ttable(void);
#endif
