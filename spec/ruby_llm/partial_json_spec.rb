# frozen_string_literal: true

require 'spec_helper'

# What a streamed structured response holds so far: the JSON read from a prefix
# of it. A string shows every character already complete; anything that could
# still change -- a number, a literal, a key -- shows only once it is whole.
RSpec.describe RubyLLM::PartialJSON do
  def prefixes(text)
    (0..text.length).map { |size| text[0, size] }
  end

  it 'reads nothing from an empty prefix' do
    expect(described_class.parse('')).to be_nil
    expect(described_class.parse("  \n")).to be_nil
  end

  it 'reads a whole document as JSON does' do
    text = '{"a": [1, -2.5e3, true, null, {"b": "c"}], "d": false, "e": "é\n"}'

    expect(described_class.parse(text)).to eq(JSON.parse(text))
  end

  it 'shows a string as far as it is written' do
    expect(described_class.parse('{"content": "Hello, wor')).to eq('content' => 'Hello, wor')
  end

  it 'leaves out a key until it is complete, and a value not yet begun' do
    expect(described_class.parse('{"reasoning": "ok", "cont')).to eq('reasoning' => 'ok')
    expect(described_class.parse('{"reasoning": "ok", "content":')).to eq('reasoning' => 'ok')
    expect(described_class.parse('{"reasoning": "ok", "content": "')).to eq('reasoning' => 'ok', 'content' => '')
  end

  it 'leaves out a number or a literal that could still grow' do
    expect(described_class.parse('{"a": 12')).to eq({})
    expect(described_class.parse('{"a": 12,')).to eq('a' => 12)
    expect(described_class.parse('{"a": tr')).to eq({})
    expect(described_class.parse('[1, 2')).to eq([1])
  end

  it 'drops an escape cut in the middle, and shows it once complete' do
    expect(described_class.parse('{"a": "x\\')).to eq('a' => 'x')
    expect(described_class.parse('{"a": "x\\n')).to eq('a' => "x\n")
    expect(described_class.parse('{"a": "x\\u00')).to eq('a' => 'x')
    expect(described_class.parse('{"a": "x\\u00e9')).to eq('a' => 'xé')
  end

  it 'joins a surrogate pair, and holds the first half until the second arrives' do
    expect(described_class.parse('{"a": "\\ud83d')).to eq('a' => '')
    expect(described_class.parse('{"a": "\\ud83d\\ude')).to eq('a' => '')
    expect(described_class.parse('{"a": "\\ud83d\\ude00')).to eq('a' => "\u{1F600}")
  end

  # Every prefix of a document reads without error, and what it shows is only
  # ever added to: a string grows at its end, and nothing shown goes away.
  it 'only grows as the document is written' do
    document = { 'reasoning' => "Looked at the card \"A\" and\nits notes \\ é \u{1F600}",
                 'content' => '**Done**: 3 items, 1.5 days', 'reply_draft' => '', 'n' => [1, 2.25, nil, true] }
    text = JSON.generate(document)

    previous = nil
    prefixes(text).each do |prefix|
      current = described_class.parse(prefix)
      expect(grows?(previous, current)).to be(true), "#{prefix.inspect}: #{current.inspect} after #{previous.inspect}"
      previous = current
    end
    expect(previous).to eq(document)
  end

  it 'refuses what is not the beginning of a JSON document' do
    expect { described_class.parse('Let me look that up.') }.to raise_error(described_class::ParseError)
    expect { described_class.parse('{"a": 1} trailing') }.to raise_error(described_class::ParseError)
    expect { described_class.parse('{"a" 1') }.to raise_error(described_class::ParseError)
    expect { described_class.parse('{"a": "\\x"}') }.to raise_error(described_class::ParseError)
  end

  def grows?(before, after)
    case before
    when nil then true
    when String then after.is_a?(String) && after.start_with?(before)
    when Hash then after.is_a?(Hash) && before.all? { |key, value| after.key?(key) && grows?(value, after[key]) }
    when Array then after.is_a?(Array) && array_grows?(before, after)
    else before == after
    end
  end

  def array_grows?(before, after)
    after.size >= before.size && before.each_with_index.all? { |value, index| grows?(value, after[index]) }
  end
end
