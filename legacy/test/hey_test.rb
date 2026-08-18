# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require_relative "../server"

class HeyEmailBodyTest < Minitest::Test
  def setup
    @integration = Madcp::Servers::Hey::Server.new(config: CONFIG)
  end

  def test_paragraphs_become_html_divs_with_blank_spacers
    html = @integration.format_hey_email_body(
      paragraphs: [
        "Ciao Luca,",
        "Seconda idea.",
        "Antonio",
      ],
    )

    assert_equal(
      "<div>Ciao Luca,</div><div><br></div><div>Seconda idea.</div><div><br></div><div>Antonio</div>",
      html,
    )
  end

  def test_message_blank_lines_become_paragraph_spacers
    html = @integration.format_hey_email_body(
      message: "Ciao Luca,\n\nSeconda idea.\n\nAntonio",
    )

    assert_equal(
      "<div>Ciao Luca,</div><div><br></div><div>Seconda idea.</div><div><br></div><div>Antonio</div>",
      html,
    )
  end

  def test_literal_backslash_n_is_expanded_when_needed
    html = @integration.format_hey_email_body(
      message: "Ciao Luca,\\n\\nSeconda idea.\\n\\nAntonio",
    )

    assert_includes html, "<div>Ciao Luca,</div>"
    assert_includes html, "<div><br></div>"
    assert_includes html, "<div>Seconda idea.</div>"
    assert_includes html, "<div>Antonio</div>"
  end

  def test_single_newlines_inside_paragraph_become_br
    html = @integration.format_hey_email_body(
      message: "Riga uno\nRiga due",
    )

    assert_equal "<div>Riga uno<br>Riga due</div>", html
  end

  def test_en_dash_bullets_become_ul
    html = @integration.format_hey_email_body(
      message: "Come lo salviamo:\n\n– Prima nota\n– Seconda nota\n\nFine.",
    )

    assert_equal(
      "<div>Come lo salviamo:</div><div><br></div>" \
      "<ul><li>Prima nota</li><li>Seconda nota</li></ul><div><br></div>" \
      "<div>Fine.</div>",
      html,
    )
  end

  def test_adjacent_bullet_paragraphs_merge_into_one_list
    html = @integration.format_hey_email_body(
      paragraphs: [
        "Intro",
        "– Uno",
        "- Due",
        "* Tre",
        "Chiusura",
      ],
    )

    assert_equal(
      "<div>Intro</div><div><br></div>" \
      "<ul><li>Uno</li><li>Due</li><li>Tre</li></ul><div><br></div>" \
      "<div>Chiusura</div>",
      html,
    )
  end

  def test_numbered_list_becomes_ol
    html = @integration.format_hey_email_body(
      paragraphs: ["1. Prima", "2. Seconda"],
    )

    assert_equal "<ol><li>Prima</li><li>Seconda</li></ol>", html
  end

  def test_mixed_intro_and_bullets_in_one_block
    html = @integration.format_hey_email_body(
      message: "Punti:\n– Alfa\n– Beta",
    )

    assert_equal "<div>Punti:</div><ul><li>Alfa</li><li>Beta</li></ul>", html
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
