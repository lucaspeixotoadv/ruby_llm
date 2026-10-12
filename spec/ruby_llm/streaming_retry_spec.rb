# frozen_string_literal: true

require 'spec_helper'

# A stream that fails after it started -- an `overloaded_error` event inside a
# 200 response, as the Anthropic API sends it -- is retried by the connection.
# What the failed attempt delivered must not survive into the next one: the
# message is the retried attempt's, and the caller is told the stream started
# over before it receives the new attempt's chunks.
RSpec.describe RubyLLM::Streaming do
  include_context 'with configured RubyLLM'

  let(:url) { 'https://api.anthropic.com/v1/messages' }
  let(:overloaded) { { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } } }
  let(:failed_attempt) { sse(start(10), text('Hel'), overloaded) }
  let(:full_attempt) { sse(start(12), text('Hello'), text(' world'), finish(3), { type: 'message_stop' }) }
  let(:event_stream) { { 'Content-Type' => 'text/event-stream' } }

  def sse(*events)
    events.map { |event| "event: #{event[:type]}\ndata: #{event.to_json}\n\n" }.join
  end

  def start(input_tokens)
    { type: 'message_start',
      message: { id: 'msg_1', model: 'claude-haiku-4-5', usage: { input_tokens: input_tokens, output_tokens: 1 } } }
  end

  def text(value)
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: value } }
  end

  def finish(output_tokens)
    { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: output_tokens } }
  end

  before do
    RubyLLM.configure { |config| config.max_retries = 1 }
    stub_request(:post, url).to_return(
      { status: 200, body: failed_attempt, headers: event_stream },
      { status: 200, body: full_attempt, headers: event_stream }
    )
  end

  it 'keeps only the retried attempt in the message' do
    message = RubyLLM.chat(model: 'claude-haiku-4-5', provider: :anthropic).ask('Hi') { |_chunk| nil }

    expect(message.content).to eq('Hello world')
    expect([message.input_tokens, message.output_tokens]).to eq([12, 3])
  end

  it 'tells the caller the stream started over, before the chunks of the new attempt' do
    received = []
    RubyLLM.chat(model: 'claude-haiku-4-5', provider: :anthropic).ask('Hi') do |chunk|
      received << (chunk.restart? ? :restart : chunk.content)
    end

    expect(received.compact).to eq(['Hel', :restart, 'Hello', ' world'])
  end

  it 'does not mark the chunks of a stream that never started over' do
    stub_request(:post, url).to_return(status: 200, body: full_attempt, headers: event_stream)
    chunks = []
    RubyLLM.chat(model: 'claude-haiku-4-5', provider: :anthropic).ask('Hi') { |chunk| chunks << chunk }

    expect(chunks).not_to be_empty
    expect(chunks.none?(&:restart?)).to be(true)
  end
end
