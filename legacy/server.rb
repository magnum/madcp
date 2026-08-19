# frozen_string_literal: true

ROOT = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "emcp"

Emcp.apply_env_sanitization!

CONFIG = Emcp::Config.new(root: ROOT)
CONFIG.validate!

REGISTRY = Emcp::Registry.new(config: CONFIG)
REGISTRY.discover!(File.join(ROOT, "servers"))

RENDERER = Emcp::Renderer.new(views_dir: File.join(ROOT, "views"))
APP = Emcp::App.configured(config: CONFIG, registry: REGISTRY, renderer: RENDERER)

APP.run! if $PROGRAM_NAME == __FILE__
