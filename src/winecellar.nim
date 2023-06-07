# Copyright © 2023 Bartek Jasicki
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met*:
# 1. Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
# 3. Neither the name of the copyright holder nor the
# names of its contributors may be used to endorse or promote products
# derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES *(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT *(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import std/[os, times]
import nuklear/nuklear_xlib

const dtime: float = 20.0

proc main() =

  var
    ctx = nuklearInit(800, 600, "Wine Cellar")
    showPopup: bool = false

  while true:
    let started = cpuTime()
    # Input
    if nuklearInput(ctx):
      break

    # GUI
    if createWin(ctx, "Main", 0, 0, 800, 600, nkWindowNoScrollbar):
      # The main menu
      nk_layout_row_dynamic(ctx, 0, 1)
      if nk_button_label(ctx, "Install a new application"):
        showPopup = true
      if nk_button_label(ctx, "Update an existing application"):
        showPopup = true
      if nk_button_label(ctx, "Remove an existing application"):
        showPopup = true
      if nk_button_label(ctx, "The program settings"):
        showPopup = true
      if nk_button_label(ctx, "About the program"):
        showPopup = true
      if nk_button_label(ctx, "Quit"):
        break
      # The message popup
      if showPopup:
        if createPopup(ctx, NK_POPUP_STATIC, "Info", nkWindowNoScrollbar, 400,
            300, 110, 80):
          nk_layout_row_dynamic(ctx, 25, 1)
          nk_label(ctx, "Not implemeted", NK_TEXT_LEFT)
          if nk_button_label(ctx, "Close"):
            showPopup = false
            nk_popup_close(ctx)
          nk_popup_end(ctx)
    nk_end(ctx)

    # Draw
    nuklearDraw()

    # Timing
    let dt = cpuTime() - started
    if (dt < dtime):
      sleep((dtime - dt).int)

  nuklearClose()

main()
