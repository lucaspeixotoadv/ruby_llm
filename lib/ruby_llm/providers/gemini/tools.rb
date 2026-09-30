# frozen_string_literal: true

require 'securerandom'

module RubyLLM
  module Providers
    class Gemini
      # Tools methods for the Gemini API implementation
      module Tools
        def format_tools(tools)
          return [] if tools.empty?

          [{
            functionDeclarations: tools.values.map { |tool| function_declaration_for(tool) }
          }]
        end

        def format_tool_call(msg) # rubocop:disable Metrics/PerceivedComplexity
          parts = []

          if msg.content && !(msg.content.respond_to?(:empty?) && msg.content.empty?)
            formatted_content = Media.format_content(msg.content)
            parts.concat(formatted_content.is_a?(Array) ? formatted_content : [formatted_content])
          end

          fallback_signature = msg.thinking&.signature
          used_fallback = false

          msg.tool_calls.each_value do |tool_call|
            part = {
              functionCall: {
                name: tool_call.name,
                args: tool_call.arguments
              }
            }

            signature = tool_call.thought_signature
            if signature.nil? && fallback_signature && !used_fallback
              signature = fallback_signature
              used_fallback = true
            end
            part[:thoughtSignature] = signature if signature
            parts << part
          end

          sign_foreign_tool_call(parts)
        end

        # The signature Gemini documents for a function call it did not write --
        # one that came from another provider, or was built by hand. Gemini 3
        # refuses a function call without a signature in the history (400
        # "Function call is missing a thought_signature").
        FOREIGN_THOUGHT_SIGNATURE = 'skip_thought_signature_validator'

        # A conversation that started on another provider reaches Gemini 3 with
        # function calls that carry no signature. The first call of the turn
        # takes the documented one, which is what Gemini checks; the others may
        # go without it, as in a parallel call Gemini wrote itself.
        def sign_foreign_tool_call(parts)
          calls = parts.select { |part| part.key?(:functionCall) }
          return parts if calls.empty? || calls.any? { |part| part[:thoughtSignature] }
          return parts unless signatures_required?

          calls.first[:thoughtSignature] = FOREIGN_THOUGHT_SIGNATURE
          parts
        end

        def signatures_required?
          @model.to_s.match?(/\Agemini-([3-9]|\d{2,})/)
        end

        def format_tool_result(msg, function_name = nil)
          function_name ||= msg.tool_call_id
          content = msg.content
          content = '(no output)' if content.nil? || (content.respond_to?(:empty?) && content.empty?)
          return format_tool_result_with_attachments(content, function_name) if tool_result_attachments?(content)

          [{
            functionResponse: {
              name: function_name,
              response: {
                name: function_name,
                content: Media.format_content(content)
              }
            }
          }]
        end

        # A tool result with files. The text stays in `response`; each file goes
        # where this model reads it as a file, and never inside the `response`
        # JSON, where it would be data -- base64 read as a string.
        #
        # Gemini 3 takes images and PDFs INSIDE the function response, as parts
        # the `response` points to by `displayName`. Anything else -- an older
        # model, an audio -- goes BESIDE it, as parts of the same turn, after the
        # function responses (`MessageFormatter#collect_tool_parts`).
        def format_tool_result_with_attachments(content, function_name)
          inside, beside = content.attachments.partition { |attachment| inside_function_response?(attachment) }
          names = inside.map { |attachment| unique_display_name(attachment) }

          text = content.text.to_s.empty? ? '(no output)' : content.text
          response = { name: function_name, content: Media.format_content(text) }
          response[:attachments] = names.map { |name| { '$ref': name } } if names.any?
          function_response = { name: function_name, response: response }
          if inside.any?
            function_response[:parts] = inside.zip(names).map do |attachment, name|
              function_response_part(attachment, name)
            end
          end

          [{ functionResponse: function_response }, *beside_parts(beside, function_name)]
        end

        def tool_result_attachments?(content)
          content.is_a?(Content) && content.attachments.any?
        end

        def inside_function_response?(attachment)
          Capabilities.multimodal_function_responses?(@model.to_s) &&
            Capabilities::FUNCTION_RESPONSE_MIME_TYPES.include?(attachment.mime_type)
        end

        def function_response_part(attachment, name)
          { inline_data: { mime_type: attachment.mime_type, display_name: name, data: attachment.encoded } }
        end

        def beside_parts(attachments, function_name)
          return [] if attachments.empty?

          [Media.format_text("Attachments returned by #{function_name}:"),
           *attachments.map { |attachment| Media.format_content_attachment(attachment) }]
        end

        # `displayName` is how the `response` points to a part, and it has to be
        # unique in the request.
        def unique_display_name(attachment)
          @tool_result_display_names ||= Set.new
          base = attachment.filename.to_s.empty? ? 'attachment' : attachment.filename.to_s
          name = base
          name = "#{@tool_result_display_names.size + 1}-#{base}" while @tool_result_display_names.include?(name)
          @tool_result_display_names << name
          name
        end

        def extract_tool_calls(data) # rubocop:disable Metrics/PerceivedComplexity
          return nil unless data

          candidate = data.is_a?(Hash) ? data.dig('candidates', 0) : nil
          return nil unless candidate

          parts = candidate.dig('content', 'parts')
          return nil unless parts.is_a?(Array)

          tool_calls = parts.each_with_object({}) do |part, result|
            function_data = part['functionCall']
            next unless function_data

            id = SecureRandom.uuid
            thought_signature = part['thoughtSignature'] || part['thought_signature']

            result[id] = ToolCall.new(
              id:,
              name: function_data['name'],
              arguments: function_data['args'] || {},
              thought_signature: thought_signature
            )
          end

          tool_calls.empty? ? nil : tool_calls
        end

        private

        def function_declaration_for(tool)
          parameters_schema = tool.params_schema ||
                              RubyLLM::Tool::SchemaDefinition.from_parameters(tool.parameters)&.json_schema

          declaration = {
            name: tool.name,
            description: tool.description
          }

          declaration[:parameters] = convert_tool_schema_to_gemini(parameters_schema) if parameters_schema

          return declaration if tool.provider_params.empty?

          RubyLLM::Utils.deep_merge(declaration, tool.provider_params)
        end

        def convert_tool_schema_to_gemini(schema)
          return nil unless schema

          schema = RubyLLM::Utils.deep_stringify_keys(schema)

          raise ArgumentError, 'Gemini tool parameters must be objects' unless schema['type'] == 'object'

          {
            type: 'OBJECT',
            properties: schema.fetch('properties', {}).transform_values { |property| convert_property(property) },
            required: (schema['required'] || []).map(&:to_s)
          }
        end

        def convert_property(property_schema) # rubocop:disable Metrics/PerceivedComplexity
          normalized_schema = normalize_any_of_schema(property_schema)
          working_schema = normalized_schema || property_schema

          type = param_type_for_gemini(working_schema['type'])

          property = {
            type: type
          }

          copy_common_attributes(property, property_schema)
          copy_common_attributes(property, working_schema)

          case type
          when 'ARRAY'
            items_schema = working_schema['items'] || property_schema['items'] || { 'type' => 'string' }
            property[:items] = convert_property(items_schema)
            copy_tool_attributes(property, working_schema, %w[minItems maxItems])
            copy_tool_attributes(property, property_schema, %w[minItems maxItems])
          when 'OBJECT'
            nested_properties = working_schema.fetch('properties', {}).transform_values do |child|
              convert_property(child)
            end
            property[:properties] = nested_properties
            required = working_schema['required'] || property_schema['required']
            property[:required] = required.map(&:to_s) if required
          end

          property
        end

        def copy_common_attributes(target, source)
          copy_tool_attributes(target, source, %w[description enum format nullable maximum minimum multipleOf])
        end

        def copy_tool_attributes(target, source, attributes)
          attributes.each do |attribute|
            value = schema_value(source, attribute)
            next if value.nil?

            target[attribute.to_sym] = value
          end
        end

        def normalize_any_of_schema(schema) # rubocop:disable Metrics/PerceivedComplexity
          any_of = schema['anyOf'] || schema[:anyOf]
          return nil unless any_of.is_a?(Array) && any_of.any?

          null_entries, non_null_entries = any_of.partition { |entry| schema_type(entry).to_s == 'null' }

          if non_null_entries.size == 1 && null_entries.any?
            normalized = RubyLLM::Utils.deep_dup(non_null_entries.first)
            normalized['nullable'] = true
            normalized
          elsif non_null_entries.any?
            RubyLLM::Utils.deep_dup(non_null_entries.first)
          else
            { 'type' => 'string', 'nullable' => true }
          end
        end

        def schema_type(schema)
          schema['type'] || schema[:type]
        end

        def schema_value(source, attribute) # rubocop:disable Metrics/PerceivedComplexity
          case attribute
          when 'multipleOf'
            source['multipleOf'] || source[:multipleOf] || source['multiple_of'] || source[:multiple_of]
          when 'minItems'
            source['minItems'] || source[:minItems] || source['min_items'] || source[:min_items]
          when 'maxItems'
            source['maxItems'] || source[:maxItems] || source['max_items'] || source[:max_items]
          else
            source[attribute] || source[attribute.to_sym]
          end
        end

        def param_type_for_gemini(type)
          case type.to_s.downcase
          when 'integer' then 'INTEGER'
          when 'number', 'float', 'double' then 'NUMBER'
          when 'boolean' then 'BOOLEAN'
          when 'array' then 'ARRAY'
          when 'object' then 'OBJECT'
          else 'STRING'
          end
        end

        def build_tool_config(tool_choice)
          {
            functionCallingConfig: {
              mode: forced_tool_choice?(tool_choice) ? 'any' : tool_choice
            }.tap do |config|
              # Use allowedFunctionNames to simulate specific tool choice
              config[:allowedFunctionNames] = [tool_choice] if specific_tool_choice?(tool_choice)
            end
          }
        end

        def forced_tool_choice?(tool_choice)
          tool_choice == :required || specific_tool_choice?(tool_choice)
        end

        def specific_tool_choice?(tool_choice)
          !%i[auto none required].include?(tool_choice)
        end
      end
    end
  end
end
