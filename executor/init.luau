local zeron = require("./zeron")("executor")

-- Executor
--
-- Zeron loads this file when the plugin is on, and reloads it as you save.
-- zeron.luau's header (next to this file) lists what each helper does and
-- which permission in zeron-plugin.json it needs. This plugin asks for none
-- yet: add the ones you use there.
--
-- For example, with "ui.add":
--
--   zeron.menu { kind = "session", id = "hello", label = zeron.s("hello.label"),
--     run = function(session) zeron.toast(zeron.s("hello.toast")) end }
--
-- Its words are in locales/: en.json, and a file per language beside it
-- (zh-Hans.json, …). zeron.t(key) shows one in Zeron's language as it
-- changes, zeron.s(key) gives it as text now; a language or a key the
-- plugin lacks shows its English.
