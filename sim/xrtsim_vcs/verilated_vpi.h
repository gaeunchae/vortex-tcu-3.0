// Stub header for VCS builds.
// The RTL DPI sources (util_dpi.cpp, float_dpi.cpp) include verilated_vpi.h
// but don't actually use any Verilator VPI functions.
// Include headers that verilated_vpi.h transitively provides.
#pragma once
#include <cstdarg>
#include <cstdint>
#include <cstdio>
