# frozen_string_literal: true

require "tmpdir"

ENV["MADCP_PUBLIC_URL"] = "http://localhost:8765"
ENV["MADCP_AUTH_USERNAME"] = "admin"
ENV["MADCP_AUTH_PASSWORD"] = "secret"
ENV["MADCP_AUTH_TOKEN"] = "static-test-token"
ENV["MADCP_ALLOWED_HOSTS"] = "localhost,127.0.0.1"
ENV["MADCP_ALLOW_WRITE"] = "false"
ENV["MADCP_REQUEST_LOG"] ||= File.join(Dir.tmpdir, "madcp-test-requests-#{Process.pid}.logs")

require "minitest/autorun"
require_relative "../server"

class HeyEmailBodyTest < Minitest::Test
  def setup
    @integration = Madcp::Servers::Hey::Server.new(config: CONFIG)
  end

  def test_paragraphs_become_html_divs
    html = @integration.format_hey_email_body(
      paragraphs: [
        "Ciao Luca,",
        "Seconda idea.",
        "1. Prima nota",
        "Antonio",
      ],
    )

    assert_equal(
      "<div>Ciao Luca,</div><div>Seconda idea.</div><div>1. Prima nota</div><div>Antonio</div>",
      html,
    )
  end

  def test_message_blank_lines_become_paragraphs
    html = @integration.format_hey_email_body(
      message: "Ciao Luca,\n\nSeconda idea.\n\nAntonio",
    )

    assert_equal(
      "<div>Ciao Luca,</div><div>Seconda idea.</div><div>Antonio</div>",
      html,
    )
  end

  def test_literal_backslash_n_is_expanded_when_needed
    html = @integration.format_hey_email_body(
      message: "Ciao Luca,\\n\\nSeconda idea.\\n\\nAntonio",
    )

    assert_includes html, "<div>Ciao Luca,</div>"
    assert_includes html, "<div>Seconda idea.</div>"
    assert_includes html, "<div>Antonio</div>"
  end

  def test_single_newlines_inside_paragraph_become_br
    html = @integration.format_hey_email_body(
      message: "Riga uno\nRiga due",
    )

    assert_equal "<div>Riga uno<br>Riga due</div>", html
  end

  def test_html_bodies_are_passed_through
    raw = "<div>Already <strong>HTML</strong></div>"
    assert_equal raw, @integration.format_hey_email_body(message: raw)
  end

  def test_special_characters_are_escaped
    html = @integration.format_hey_email_body(paragraphs: ['A <b> & "quote"'])
    assert_equal "<div>A &lt;b&gt; &amp; &quot;quote&quot;</div>", html
  end

  def test_compose_tool_accepts_paragraphs
    tools = @integration.tool_catalog
    compose = tools.find { |tool| tool[:name] == "hey_compose" }
    reply = tools.find { |tool| tool[:name] == "hey_reply" }

    assert compose[:input_schema][:properties].key?(:paragraphs)
    assert reply[:input_schema][:properties].key?(:paragraphs)
    assert_equal ["subject"], compose[:input_schema][:required]
    assert_equal ["topic_id"], reply[:input_schema][:required]
  end
end
