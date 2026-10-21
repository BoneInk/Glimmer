#include "dialect_inner.h"

vec3 Outer(vec3 color) { return Inner(color) * 0.5; }
