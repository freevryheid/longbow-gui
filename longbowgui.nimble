# Package

version       = "0.1.0"
author        = "Andre Smit"
description   = "An SDL based gui for Longbow"
license       = "MIT"
skipExt       = @["nim"]
bin           = @["longbowgui"]

# Dependencies

requires "nim >= 1.0.0"
requires "cligen >= 0.9.41"
requires "turn_based_game >= 1.1.6"
requires "negamax >= 0.0.3"
requires "sdl2 >= 2.0.2"
requires "longbow >= 1.1.0"
