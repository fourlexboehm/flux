#include "imgui.h"

extern "C" float fluxZguiGetMouseWheelY(void) {
    return ImGui::GetIO().MouseWheel;
}
