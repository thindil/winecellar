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

## Various code not related to any particular option

import std/[httpclient, net, os, strutils]
import contracts

let
  homeDir*: string = getEnv(key = "HOME")
    ## The path to the user's home directory
  dataDir*: string = homeDir & "/.local/share/winecellar/"
    ## The path to the program's data directory, where Wine will be installed
  configDir*: string = homeDir & "/.config/winecellar/"
    ## The path to the program's configuration directory
  cacheDir*: string = homeDir & "/.cache/winecellar/"
    ## The path to the program's cache directory, for temporary files

type
  ThreadData* = seq[string]
    ## The data send to the child thread of the programs, depends on the task to do.
  ProgramState* = enum
    ## The states of the program
    mainMenu, newApp, newAppWine, newAppDownload, appExec, updateApp, appSettings


proc downloadFile*(data: ThreadData) {.thread, nimcall, contractual, raises: [
    ValueError, TimeoutError, ProtocolError, OSError, IOError, Exception],
    tags: [WriteIOEffect, TimeEffect, ReadIOEffect, RootEffect].} =
  ## Download the selected file from URL to file
  ##
  ## * data - the data for download, the first element is the URL from which
  ##          the download will be taken, the second element is the name of the
  ##          local file in which the content of the URL will be saved
  require:
    data.len == 2 and data[0].len > 0 and data[1].len > 0
  body:
    let client: HttpClient = newHttpClient(timeout = 5000)
    client.downloadFile(url = data[0], filename = data[1])
