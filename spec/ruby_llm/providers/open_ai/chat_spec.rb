# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::OpenAI::Chat do
  describe '.parse_completion_response' do
    it 'captures cached token information when present' do
      response_body = {
        'model' => 'gpt-4.1-nano',
        'choices' => [
          {
            'message' => {
              'role' => 'assistant',
              'content' => 'Hello!'
            }
          }
        ],
        'usage' => {
          'prompt_tokens' => 8,
          'completion_tokens' => 4,
          'prompt_tokens_details' => { 'cached_tokens' => 6 }
        }
      }

      response = instance_double(Faraday::Response, body: response_body)
      allow(described_class).to receive(:parse_tool_calls).and_return(nil)

      message = described_class.parse_completion_response(response)

      expect(message.cached_tokens).to eq(6)
      expect(message.input_tokens).to eq(2)
      expect(message.output_tokens).to eq(4)
      # The response reports no cache writes, so the count is unknown - not a
      # measured zero.
      expect(message.cache_creation_tokens).to be_nil
    end

    it 'normalizes DeepSeek cache hit and miss usage fields' do
      response_body = {
        'model' => 'deepseek-chat',
        'choices' => [
          {
            'message' => {
              'role' => 'assistant',
              'content' => 'Hello!'
            }
          }
        ],
        'usage' => {
          'prompt_tokens' => 206,
          'completion_tokens' => 4,
          'prompt_cache_hit_tokens' => 192,
          'prompt_cache_miss_tokens' => 14
        }
      }

      response = instance_double(Faraday::Response, body: response_body)
      allow(described_class).to receive(:parse_tool_calls).and_return(nil)

      message = described_class.parse_completion_response(response)

      expect(message.input_tokens).to eq(14)
      expect(message.cached_tokens).to eq(192)
      expect(message.output_tokens).to eq(4)
      expect(message.cache_creation_tokens).to be_nil
    end

    it 'keeps OpenAI reasoning tokens inside completion output tokens' do
      response_body = {
        'model' => 'gpt-5.5',
        'choices' => [
          {
            'message' => {
              'role' => 'assistant',
              'content' => 'Hello!'
            }
          }
        ],
        'usage' => {
          'prompt_tokens' => 50,
          'completion_tokens' => 1306,
          'total_tokens' => 1356,
          'completion_tokens_details' => { 'reasoning_tokens' => 1087 }
        }
      }

      response = instance_double(Faraday::Response, body: response_body)
      allow(described_class).to receive(:parse_tool_calls).and_return(nil)

      message = described_class.parse_completion_response(response)

      expect(message.output_tokens).to eq(1306)
      expect(message.thinking_tokens).to eq(1087)
    end

    it 'adds reasoning tokens to output for OpenAI-compatible providers that report them separately' do
      response_body = {
        'model' => 'grok-4-fast-reasoning',
        'choices' => [
          {
            'message' => {
              'role' => 'assistant',
              'content' => 'Hello!'
            }
          }
        ],
        'usage' => {
          'prompt_tokens' => 43,
          'completion_tokens' => 101,
          'total_tokens' => 9971,
          'completion_tokens_details' => { 'reasoning_tokens' => 9827 }
        }
      }

      response = instance_double(Faraday::Response, body: response_body)
      allow(described_class).to receive(:parse_tool_calls).and_return(nil)

      message = described_class.parse_completion_response(response)

      expect(message.output_tokens).to eq(9928)
      expect(message.thinking_tokens).to eq(9827)
    end

    it 'captures top-level reasoning tokens when providers report them outside completion details' do
      response_body = {
        'model' => 'sonar-deep-research',
        'choices' => [
          {
            'message' => {
              'role' => 'assistant',
              'content' => 'Hello!'
            }
          }
        ],
        'usage' => {
          'prompt_tokens' => 33,
          'completion_tokens' => 11_395,
          'total_tokens' => 11_428,
          'reasoning_tokens' => 193_947
        }
      }

      response = instance_double(Faraday::Response, body: response_body)
      allow(described_class).to receive(:parse_tool_calls).and_return(nil)

      message = described_class.parse_completion_response(response)

      expect(message.output_tokens).to eq(11_395)
      expect(message.thinking_tokens).to eq(193_947)
    end
  end

  describe '.format_messages' do
    it 'opts OpenAI into native file parts for PDF attachments' do
      content = RubyLLM::Content.new('Summarize this file')
      content.add_attachment(StringIO.new('pdf bytes'), filename: 'proposal.pdf')

      messages = [RubyLLM::Message.new(role: :user, content:)]

      formatted = RubyLLM::Providers::OpenAI.allocate.send(:format_messages, messages)

      expect(formatted.dig(0, :content, 1, :type)).to eq('file')
      expect(formatted.dig(0, :content, 1, :file, :filename)).to eq('proposal.pdf')
    end

    it 'keeps non-PDF documents disabled for OpenAI chat completions' do
      expect do
        RubyLLM::Providers::OpenAI.allocate.send(:format_messages, [docx_message])
      end.to raise_error(
        RubyLLM::UnsupportedAttachmentError,
        %r{Unsupported attachment type: application/vnd.openxmlformats-officedocument.wordprocessingml.document}
      )
    end

    it 'keeps unsupported files disabled for DeepSeek' do
      provider = RubyLLM::Providers::DeepSeek.allocate

      expect do
        provider.send(:format_messages, [docx_message])
      end.to raise_error(
        RubyLLM::UnsupportedAttachmentError,
        %r{Unsupported attachment type: application/vnd.openxmlformats-officedocument.wordprocessingml.document}
      )
    end

    it 'keeps image attachments disabled for DeepSeek' do
      provider = RubyLLM::Providers::DeepSeek.allocate
      content = RubyLLM::Content.new('Describe this')
      content.add_attachment(StringIO.new('png bytes'), filename: 'image.png')

      expect do
        provider.send(:format_messages, [RubyLLM::Message.new(role: :user, content:)])
      end.to raise_error(RubyLLM::UnsupportedAttachmentError, %r{Unsupported attachment type: image/png})
    end

    it 'uses Perplexity file_url parts for supported file attachments' do
      provider = RubyLLM::Providers::Perplexity.allocate

      formatted = provider.send(:format_messages, [docx_message])

      expect(formatted.dig(0, :content, 1)).to eq(
        type: 'file_url',
        file_url: { url: Base64.strict_encode64('docx bytes') }
      )
    end

    it 'keeps Perplexity text file attachments as text parts' do
      provider = RubyLLM::Providers::Perplexity.allocate

      %w[csv txt md html json].each do |extension|
        content = RubyLLM::Content.new('Summarize this file')
        content.add_attachment(StringIO.new('notes'), filename: "notes.#{extension}")

        formatted = provider.send(:format_messages, [RubyLLM::Message.new(role: :user, content:)])
        attachment = content.attachments.first

        expect(formatted.dig(0, :content, 1)).to eq(
          type: 'text',
          text: attachment.for_llm
        )
      end
    end

    it 'keeps unsupported files disabled for xAI' do
      provider = RubyLLM::Providers::XAI.allocate

      expect do
        provider.send(:format_messages, [docx_message])
      end.to raise_error(
        RubyLLM::UnsupportedAttachmentError,
        %r{Unsupported attachment type: application/vnd.openxmlformats-officedocument.wordprocessingml.document}
      )
    end

    it 'keeps PDF file parts disabled for xAI chat completions' do
      provider = RubyLLM::Providers::XAI.allocate
      content = RubyLLM::Content.new('Summarize this file')
      content.add_attachment(StringIO.new('pdf bytes'), filename: 'proposal.pdf')

      expect do
        provider.send(:format_messages, [RubyLLM::Message.new(role: :user, content:)])
      end.to raise_error(RubyLLM::UnsupportedAttachmentError, %r{Unsupported attachment type: application/pdf})
    end

    def docx_message
      content = RubyLLM::Content.new('Summarize this file')
      content.add_attachment(StringIO.new('docx bytes'), filename: 'proposal.docx')
      RubyLLM::Message.new(role: :user, content:)
    end
  end

  describe '.render_payload' do
    let(:model) { instance_double(RubyLLM::Model::Info, id: 'gpt-4o') }
    let(:messages) { [RubyLLM::Message.new(role: :user, content: 'Hello')] }

    before do
      allow(described_class).to receive(:format_messages).and_return([{ role: 'user', content: 'Hello' }])
    end

    context 'with schema' do
      it 'uses canonical wrapped schema payload' do
        schema = {
          name: 'response',
          schema: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              age: { type: 'integer' }
            }
          },
          strict: true
        }

        payload = described_class.render_payload(
          messages,
          tools: {},
          temperature: nil,
          model: model,
          stream: false,
          schema: schema
        )

        expect(payload[:response_format][:json_schema][:name]).to eq('response')
        expect(payload[:response_format][:json_schema][:schema]).to eq(schema[:schema])
        expect(payload[:response_format][:json_schema][:strict]).to be(true)
      end

      it 'uses custom schema name when provided in full format' do
        schema = {
          name: 'PersonSchema',
          schema: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              age: { type: 'integer' }
            }
          },
          strict: true
        }

        payload = described_class.render_payload(
          messages,
          tools: {},
          temperature: nil,
          model: model,
          stream: false,
          schema: schema
        )

        expect(payload[:response_format][:json_schema][:name]).to eq('PersonSchema')
        expect(payload[:response_format][:json_schema][:schema]).to eq(schema[:schema])
        expect(payload[:response_format][:json_schema][:strict]).to be(true)
      end

      it 'respects explicit strict: false' do
        schema = {
          name: 'PersonSchema',
          schema: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              age: { type: 'integer' }
            }
          },
          strict: false
        }

        payload = described_class.render_payload(
          messages,
          tools: {},
          temperature: nil,
          model: model,
          stream: false,
          schema: schema
        )

        expect(payload[:response_format][:json_schema][:strict]).to be(false)
      end
    end
  end

  describe '.render_payload with thinking' do
    let(:user_message) { RubyLLM::Message.new(role: :user, content: 'Hello') }

    before do
      allow(described_class).to receive(:format_messages).and_return([{ role: 'user', content: 'Hello' }])
    end

    def render_payload(model_id:, thinking:, provider: 'openai', capabilities: %w[reasoning])
      model = RubyLLM::Model::Info.new(id: model_id, provider: provider, capabilities: capabilities)

      described_class.render_payload(
        [user_message],
        tools: {},
        temperature: nil,
        model: model,
        stream: false,
        thinking: thinking
      )
    end

    it 'sends an effort as reasoning_effort' do
      payload = render_payload(model_id: 'gpt-5.4', thinking: RubyLLM::Thinking::Config.new(effort: :medium))

      expect(payload[:reasoning_effort]).to eq('medium')
      expect(payload).not_to have_key(:thinking)
    end

    it 'sends no reasoning field when thinking was never configured' do
      payload = render_payload(model_id: 'gpt-4o', thinking: nil, capabilities: [])

      expect(payload).not_to have_key(:reasoning_effort)
    end

    it 'refuses a thinking budget instead of dropping it' do
      # Chat completions has no field for a token budget, so the setting could
      # never reach the provider. It used to disappear between with_thinking
      # and the payload, leaving the caller with an unreasoned answer and no
      # indication why.
      expect do
        render_payload(model_id: 'gpt-5.4', thinking: RubyLLM::Thinking::Config.new(budget: 2048))
      end.to raise_error(ArgumentError, /budget is not supported for gpt-5\.4/)
    end

    it 'refuses a budget even when an effort is given alongside it' do
      expect do
        render_payload(
          model_id: 'gpt-5.4',
          thinking: RubyLLM::Thinking::Config.new(effort: :low, budget: 2048)
        )
      end.to raise_error(ArgumentError, /with_thinking\(effort:\)/)
    end

    it 'refuses a budget for every provider speaking this dialect' do
      %w[azure deepseek xai perplexity].each do |provider|
        expect do
          render_payload(model_id: 'a-model', provider: provider, thinking: RubyLLM::Thinking::Config.new(budget: 1024))
        end.to raise_error(ArgumentError)
      end
    end
  end
end
