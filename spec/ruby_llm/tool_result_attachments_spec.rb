# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::ToolResultAttachments do
  include_context 'with configured RubyLLM'

  let(:image_path) { File.expand_path('../fixtures/ruby.png', __dir__) }
  let(:pdf_path) { File.expand_path('../fixtures/sample.pdf', __dir__) }

  def call_message(*ids)
    tool_calls = ids.to_h { |id| [id, RubyLLM::ToolCall.new(id: id, name: 'read_file', arguments: {})] }
    RubyLLM::Message.new(role: :assistant, content: '', tool_calls: tool_calls)
  end

  def tool_result(id, content)
    RubyLLM::Message.new(role: :tool, content: content, tool_call_id: id)
  end

  describe '.relocate' do
    it 'returns the same list when no tool result has attachments' do
      messages = [call_message('call_1'), tool_result('call_1', '{"ok":true}')]

      expect(described_class.relocate(messages)).to equal(messages)
    end

    it 'keeps the text of the tool result and moves its files to a user message right after it' do
      messages = [
        RubyLLM::Message.new(role: :user, content: 'read it'),
        call_message('call_1'),
        tool_result('call_1', RubyLLM::Content.new('{"status":"attached"}', [image_path]))
      ]

      relocated = described_class.relocate(messages)

      expect(relocated.map(&:role)).to eq(%i[user assistant tool user])
      expect(relocated[2].content).to eq("{\"status\":\"attached\"}\n\n#{described_class::NOTE}")
      expect(relocated[2].tool_call_id).to eq('call_1')
      expect(relocated[3].content.attachments.map(&:mime_type)).to eq(['image/png'])
      expect(relocated[3].content.text).to include('call_1 (1)')
    end

    # The API wants every tool result right after the call that asked for it:
    # the files of parallel calls wait for the last result, and go together.
    it 'gathers the files of parallel calls after the last of their results' do
      messages = [
        call_message('call_1', 'call_2', 'call_3'),
        tool_result('call_1', RubyLLM::Content.new('one', [image_path])),
        tool_result('call_2', 'plain text'),
        tool_result('call_3', RubyLLM::Content.new('three', [pdf_path])),
        RubyLLM::Message.new(role: :assistant, content: 'done')
      ]

      relocated = described_class.relocate(messages)

      expect(relocated.map(&:role)).to eq(%i[assistant tool tool tool user assistant])
      expect(relocated[2].content).to eq('plain text')
      expect(relocated[4].content.attachments.map(&:mime_type)).to eq(%w[image/png application/pdf])
      expect(relocated[4].content.text).to include('call_1 (1), call_3 (1)')
    end

    it 'says the files follow when the tool answered with files only' do
      relocated = described_class.relocate([call_message('call_1'),
                                            tool_result('call_1', RubyLLM::Content.new(nil, [image_path]))])

      expect(relocated[1].content).to eq(described_class::NOTE)
    end

    it 'leaves the chat history as it was' do
      result = tool_result('call_1', RubyLLM::Content.new('one', [image_path]))

      described_class.relocate([call_message('call_1'), result])

      expect(result.content.attachments.size).to eq(1)
    end
  end

  # Where the provider decides: an API that carries files in a tool result gets
  # the history as it is; one that does not gets the relocated list.
  describe 'in Provider#complete' do
    let(:model) { instance_double(RubyLLM::Model::Info, id: 'gpt-4.1-mini', provider: 'openai') }
    let(:messages) do
      [RubyLLM::Message.new(role: :user, content: 'read it'), call_message('call_1'),
       tool_result('call_1', RubyLLM::Content.new('{"status":"attached"}', [image_path]))]
    end

    def payload_of(provider)
      captured = nil
      allow(provider).to receive(:sync_response) do |_connection, payload, _headers|
        captured = payload
        RubyLLM::Message.new(role: :assistant, content: 'ok')
      end
      provider.complete(messages, tools: {}, temperature: nil, model: model)
      captured
    end

    it 'sends OpenAI a text-only tool message and the file in a user message after it' do
      payload = payload_of(RubyLLM::Providers::OpenAI.new(RubyLLM.config))

      tool, files = payload[:messages].last(2)
      expect(tool).to include(role: 'tool', tool_call_id: 'call_1')
      expect(tool[:content]).to be_a(String)
      expect(tool[:content]).not_to include('base64')
      expect(files[:role]).to eq('user')
      expect(files[:content].map { |part| part[:type] }).to eq(%w[text image_url])
    end

    it 'sends Anthropic the file inside the tool result' do
      anthropic_model = instance_double(RubyLLM::Model::Info, id: 'claude-sonnet-4-5', provider: 'anthropic',
                                                              max_tokens: 1024)
      provider = RubyLLM::Providers::Anthropic.new(RubyLLM.config)
      captured = nil
      allow(provider).to receive(:sync_response) do |_connection, payload, _headers|
        captured = payload
        RubyLLM::Message.new(role: :assistant, content: 'ok')
      end

      provider.complete(messages, tools: {}, temperature: nil, model: anthropic_model)

      tool_result = captured[:messages].last[:content].first
      expect(tool_result[:type]).to eq('tool_result')
      expect(tool_result[:content].map { |block| block[:type] }).to eq(%w[text image])
    end
  end
end
