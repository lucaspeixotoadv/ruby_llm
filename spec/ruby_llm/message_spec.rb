# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Message do
  let(:model) do
    RubyLLM::Model::Info.new(
      id: 'priced-model',
      name: 'Priced Model',
      provider: 'openai',
      pricing: {
        text_tokens: {
          standard: {
            input_per_million: 1.0,
            output_per_million: 2.0
          }
        }
      }
    )
  end

  describe '#content' do
    it 'normalizes nil content to empty string for assistant tool-call messages' do
      tool_call = RubyLLM::ToolCall.new(id: 'call_1', name: 'weather', arguments: {})
      message = described_class.new(role: :assistant, content: nil, tool_calls: { 'call_1' => tool_call })

      expect(message.content).to eq('')
    end

    it 'keeps nil content for messages without tool calls' do
      message = described_class.new(role: :assistant, content: nil, tool_calls: nil)

      expect(message.content).to be_nil
    end
  end

  describe '#cost' do
    it 'calculates cost from the supplied model' do
      message = described_class.new(role: :assistant, content: 'Hello', input_tokens: 1_000, output_tokens: 2_000)

      expect(message.cost(model: model).total).to eq(0.005)
      expect(message.cost(model: model).to_h).to include(input: 0.001, output: 0.004, total: 0.005)
    end

    it 'uses model_id for cost lookup' do
      allow(RubyLLM.models).to receive(:find).and_call_original
      allow(RubyLLM.models).to receive(:find).with('priced-model').and_return(model)

      message = described_class.new(
        role: :assistant,
        content: 'Hello',
        input_tokens: 1_000,
        output_tokens: 2_000,
        model_id: 'priced-model'
      )

      expect(message.cost.total).to eq(0.005)
    end

    it 'returns nil when the message model cannot be found' do
      message = described_class.new(
        role: :assistant,
        content: 'Hello',
        input_tokens: 1_000,
        model_id: 'missing-model'
      )

      expect(message.cost.total).to be_nil
    end
  end

  describe 'cache token aliases' do
    it 'exposes cache_read_tokens and cache_write_tokens' do
      message = described_class.new(
        role: :assistant,
        content: 'Hello',
        cached_tokens: 42,
        cache_creation_tokens: 7
      )

      expect(message.cache_read_tokens).to eq(42)
      expect(message.cache_write_tokens).to eq(7)
      expect(message.tokens.cache_read).to eq(42)
      expect(message.tokens.cache_write).to eq(7)
    end
  end

  describe '.tool_result' do
    it 'keeps the text a tool returned, unmarked' do
      message = described_class.tool_result(tool_call_id: 'call_1', result: 'done')

      expect(message.role).to eq(:tool)
      expect(message.tool_call_id).to eq('call_1')
      expect(message.content).to eq('done')
      expect(message).not_to be_tool_error
    end

    it 'turns any other value into its text' do
      message = described_class.tool_result(tool_call_id: 'call_1', result: 42)

      expect(message.content).to eq('42')
    end

    it 'keeps a Content as it is' do
      content = RubyLLM::Content.new('attached', [File.expand_path('../fixtures/ruby.png', __dir__)])

      expect(described_class.tool_result(tool_call_id: 'call_1', result: content).content).to equal(content)
    end

    it 'takes the content of a halt' do
      message = described_class.tool_result(tool_call_id: 'call_1', result: RubyLLM::Tool::Halt.new('stop here'))

      expect(message.content).to eq('stop here')
      expect(message).not_to be_tool_error
    end

    it 'marks the message when the tool returned an error result' do
      result = RubyLLM::Tool::ErrorResult.new('{"error":{"code":"not_found"}}')
      message = described_class.tool_result(tool_call_id: 'call_1', result:)

      expect(message.content).to eq('{"error":{"code":"not_found"}}')
      expect(message).to be_tool_error
    end
  end

  describe '#tool_error?' do
    it 'is false unless the message is marked' do
      expect(described_class.new(role: :tool, content: 'ok', tool_call_id: 'call_1')).not_to be_tool_error
    end

    it 'goes into to_h only when the message is marked' do
      marked = described_class.new(role: :tool, content: 'no', tool_call_id: 'call_1', tool_error: true)
      unmarked = described_class.new(role: :tool, content: 'ok', tool_call_id: 'call_1')

      expect(marked.to_h).to include(tool_error: true)
      expect(unmarked.to_h).not_to have_key(:tool_error)
    end

    it 'refuses the mark on a message that is not a tool result' do
      expect { described_class.new(role: :assistant, content: 'no', tool_error: true) }
        .to raise_error(ArgumentError, 'Only a tool result can be marked as an error')
    end

    it 'refuses a mark that is not a boolean' do
      expect { described_class.new(role: :tool, content: 'no', tool_call_id: 'call_1', tool_error: nil) }
        .to raise_error(ArgumentError, /Expected tool_error to be true or false/)
    end
  end
end
