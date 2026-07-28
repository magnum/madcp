# frozen_string_literal: true

ROOT = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "madcp"

Madcp.apply_env_sanitization!

CONFIG = Madcp::Config.new(root: ROOT)
CONFIG.validate!

REGISTRY = Madcp::Registry.new(config: CONFIG)
REGISTRY.discover!(File.join(ROOT, "servers"))

RENDERER = Madcp::Renderer.new(views_dir: File.join(ROOT, "views"))
APP = Madcp::App.configured(config: CONFIG, registry: REGISTRY, renderer: RENDERER)

APP.run! if $PROGRAM_NAME == __FILE__
