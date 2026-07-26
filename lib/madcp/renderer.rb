# frozen_string_literal: true

require "erb"

module Madcp
  class Renderer
    class Context
      include ERB::Util

      def initialize(locals)
        locals.each { |key, value| define_singleton_method(key) { value } }
      end

      def get_binding = binding
    end

    def initialize(views_dir:)
      @views_dir = views_dir
    end

    def page(template, **locals)
      content = render(template, **locals)
      render(
        "layout",
        **locals.merge(
          content: content,
          title: locals.fetch(:title, "MadCP"),
          year: Time.now.year,
        ),
      )
    end

    def render(template, **locals)
      path = File.join(@views_dir, "#{template}.html.erb")
      raise "missing view: #{path}" unless File.file?(path)

      ERB.new(File.read(path), trim_mode: "-").result(Context.new(locals).get_binding)
    end
  end
end
