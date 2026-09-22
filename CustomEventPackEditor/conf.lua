-- conf.lua -- LÖVE 11.5 window configuration
-- The editor is a desktop tool: resizable window, vsync on, stencil buffer
-- enabled (the graph clips node icons with a stencil circle).

function love.conf(t)
  t.identity = "CustomEventPackEditor"
  t.version = "11.5"
  t.console = false

  t.window.title = "Cell to Singularity - Custom Event Pack Editor"
  t.window.width = 1500
  t.window.height = 950
  t.window.minwidth = 900
  t.window.minheight = 600
  t.window.resizable = true
  t.window.vsync = 1
  t.window.msaa = 0
  t.window.highdpi = false
  t.window.stencil = true

  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
  t.modules.touch = false
end
