# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::Gemini::CachedContents do
  include_context 'with configured RubyLLM'

  let(:provider) { RubyLLM::Providers::Gemini.new(RubyLLM.config) }
  let(:model) { RubyLLM::Model::Info.default('gemini-3.8-flash', 'gemini') }
  let(:tool_class) do
    Class.new(RubyLLM::Tool) do
      def self.name = 'LookupCase'
      description 'Looks up a case'
      param :document, desc: 'CPF of the holder'

      def execute(document:) = document
    end
  end
  let(:tools) { { lookup_case: tool_class.new } }
  let(:messages) do
    [RubyLLM::Message.new(role: :system, content: 'You are Ana.'),
     RubyLLM::Message.new(role: :user, content: 'Hi')]
  end

  describe '#cached_content_payload' do
    it 'holds the system instruction and the tools, as a request carries them' do
      payload = provider.cached_content_payload(messages, tools: tools, model: model)
      request = provider.send(:render_payload, messages, tools: tools, temperature: nil, model: model)

      expect(payload[:model]).to eq('models/gemini-3.8-flash')
      expect(payload[:systemInstruction]).to eq(request[:systemInstruction])
      expect(payload[:tools]).to eq(request[:tools])
      expect(payload).not_to have_key(:contents)
    end

    it 'holds the calling mode of strict tools, which the request that names it cannot carry' do
      tool_class.strict
      payload = provider.cached_content_payload(messages, tools: tools, model: model)
      request = provider.send(:render_payload, messages, tools: tools, temperature: nil, model: model)

      expect(payload[:toolConfig]).to eq(functionCallingConfig: { mode: 'VALIDATED' })
      expect(payload[:toolConfig]).to eq(request[:toolConfig])
    end

    it 'leaves the calling mode out for tools that are not strict' do
      expect(provider.cached_content_payload(messages, tools: tools, model: model)).not_to have_key(:toolConfig)
    end

    it 'leaves the tools out when there are none' do
      expect(provider.cached_content_payload(messages, tools: {}, model: model)).not_to have_key(:tools)
    end
  end

  describe '#create_cached_content' do
    it 'stores the payload for the given seconds and returns the cache' do
      stub = stub_request(:post, 'https://generativelanguage.googleapis.com/v1beta/cachedContents')
             .with(body: hash_including('ttl' => '3600s', 'model' => 'models/gemini-3.8-flash'))
             .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                        body: { name: 'cachedContents/abc', expireTime: '2026-09-30T19:00:00Z',
                                usageMetadata: { totalTokenCount: 5548 } }.to_json)

      cache = provider.create_cached_content({ model: 'models/gemini-3.8-flash' }, ttl: 3600)

      expect(stub).to have_been_requested
      expect(cache.name).to eq('cachedContents/abc')
      expect(cache.expires_at).to eq(Time.utc(2026, 9, 30, 19))
      expect(cache.tokens).to eq(5548)
    end
  end

  # Gemini refuses a request that names a cache and repeats what it holds.
  describe '#finalize_payload' do
    it 'drops the cached fields when the request names a cache' do
      payload = { contents: [], systemInstruction: {}, tools: [], toolConfig: {}, cachedContent: 'cachedContents/abc' }

      expect(provider.finalize_payload(payload).keys).to contain_exactly(:contents, :cachedContent)
    end

    it 'keeps them otherwise' do
      payload = { contents: [], systemInstruction: {}, tools: [] }

      expect(provider.finalize_payload(payload)).to eq(payload)
    end
  end

  def names_cache_only?(body)
    body['cachedContent'] == 'cachedContents/abc' && !body.key?('systemInstruction') && !body.key?('tools')
  end

  it 'sends a request that names the cache without the cached fields' do
    stub = stub_request(:post, %r{models/gemini-3.8-flash:generateContent})
           .with { |request| names_cache_only?(JSON.parse(request.body)) }
           .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                      body: { candidates: [{ content: { role: 'model', parts: [{ text: 'Oi' }] } }],
                              usageMetadata: { promptTokenCount: 5600, cachedContentTokenCount: 5548,
                                               candidatesTokenCount: 2 } }.to_json)

    chat = RubyLLM.chat(model: 'gemini-3.8-flash', provider: :gemini, assume_model_exists: true)
                  .with_instructions('You are Ana.').with_tool(tool_class)
                  .with_params(cachedContent: 'cachedContents/abc')
    response = chat.ask('Hi')

    expect(stub).to have_been_requested
    expect(response.cached_tokens).to eq(5548)
  end
end
