# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::Gemini::Tools do
  include_context 'with configured RubyLLM'

  let(:test_obj) do
    Object.new.tap { |obj| obj.extend(described_class) }
  end

  describe '#extract_tool_calls' do
    it 'captures all function calls returned in a single candidate' do
      data = {
        'candidates' => [
          {
            'content' => {
              'parts' => [
                { 'functionCall' => { 'name' => 'weather',
                                      'args' => { 'latitude' => '52.5200', 'longitude' => '13.4050' } } },
                { 'functionCall' => { 'name' => 'best_language_to_learn', 'args' => {} } }
              ]
            }
          }
        ]
      }

      tool_calls = test_obj.extract_tool_calls(data)

      expect(tool_calls&.size).to eq(2)
      expect(tool_calls.values.map(&:name)).to eq(%w[weather best_language_to_learn])
      expect(tool_calls.values.last.arguments).to eq({})
    end
  end

  describe '#format_tool_call' do
    it 'outputs a functionCall part for each tool call and preserves assistant text' do
      tool_calls = {
        'a' => RubyLLM::ToolCall.new(id: 'a', name: 'weather', arguments: { 'latitude' => '52.5200' }),
        'b' => RubyLLM::ToolCall.new(id: 'b', name: 'best_language_to_learn', arguments: {})
      }
      message = RubyLLM::Message.new(role: :assistant, content: 'Working on it...', tool_calls:)

      result = test_obj.format_tool_call(message)

      expect(result.length).to eq(3)
      expect(result.first).to eq({ text: 'Working on it...' })
      expect(result[1][:functionCall]).to eq(name: 'weather', args: { 'latitude' => '52.5200' })
      expect(result[2][:functionCall]).to eq(name: 'best_language_to_learn', args: {})
    end
  end

  describe '#format_tool_result' do
    it 'uses the tool call id for Gemini function responses' do
      message = RubyLLM::Message.new(
        role: :tool,
        content: 'Result payload',
        tool_call_id: 'uuid-123'
      )

      result = test_obj.format_tool_result(message)

      expect(result).to eq([
                             {
                               functionResponse: {
                                 name: 'uuid-123',
                                 response: {
                                   name: 'uuid-123',
                                   content: [{ text: 'Result payload' }]
                                 }
                               }
                             }
                           ])
    end

    it 'uses a placeholder when the tool returns no content' do
      message = RubyLLM::Message.new(
        role: :tool,
        content: '',
        tool_call_id: 'uuid-123'
      )

      result = test_obj.format_tool_result(message)

      expect(result).to eq([
                             {
                               functionResponse: {
                                 name: 'uuid-123',
                                 response: {
                                   name: 'uuid-123',
                                   content: [{ text: '(no output)' }]
                                 }
                               }
                             }
                           ])
    end

    # A file in a tool result is never data inside the `response` JSON: Gemini
    # would read the base64 as a string.
    describe 'with attachments' do
      let(:image_path) { File.expand_path('../../../fixtures/ruby.png', __dir__) }
      let(:audio_path) { File.expand_path('../../../fixtures/ruby.mp3', __dir__) }

      def result_for(model_id, attachments)
        test_obj.instance_variable_set(:@model, model_id)
        message = RubyLLM::Message.new(role: :tool, tool_call_id: 'read_file',
                                       content: RubyLLM::Content.new('{"status":"attached"}', attachments))
        test_obj.format_tool_result(message)
      end

      it 'puts an image inside the function response on Gemini 3, pointed to by its display name' do
        result = result_for('gemini-3.5-flash', [image_path])

        expect(result.size).to eq(1)
        function_response = result.first[:functionResponse]
        expect(function_response[:response]).to eq(
          name: 'read_file', content: [{ text: '{"status":"attached"}' }], attachments: [{ '$ref': 'ruby.png' }]
        )
        inline = function_response[:parts].first[:inline_data]
        expect(inline).to include(mime_type: 'image/png', display_name: 'ruby.png')
        expect(function_response[:response].to_json).not_to include(inline[:data])
      end

      it 'puts the file beside the function response on a model before Gemini 3' do
        result = result_for('gemini-2.5-flash', [image_path])

        expect(result.first[:functionResponse]).not_to have_key(:parts)
        expect(result.first[:functionResponse][:response]).not_to have_key(:attachments)
        expect(result[1]).to eq({ text: 'Attachments returned by read_file:' })
        expect(result[2][:inline_data][:mime_type]).to eq('image/png')
      end

      it 'puts a type the function response does not take beside it, even on Gemini 3' do
        result = result_for('gemini-3.5-flash', [image_path, audio_path])

        expect(result.first[:functionResponse][:parts].map do |part|
          part[:inline_data][:mime_type]
        end).to eq(['image/png'])
        expect(result.last[:inline_data][:mime_type]).to eq('audio/mpeg')
      end

      it 'keeps display names unique across the request' do
        first = result_for('gemini-3.5-flash', [image_path])
        second = result_for('gemini-3.5-flash', [image_path])

        names = [first, second].map do |result|
          result.first[:functionResponse][:parts].first[:inline_data][:display_name]
        end
        expect(names.uniq.size).to eq(2)
      end
    end
  end
end
