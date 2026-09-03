# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Decides whether a temperature reaches the OpenAI-compatible payload.
      #
      # The registry states this per model (models.dev's `temperature` field,
      # read through Model::Info#rejects_temperature?), so nothing here matches
      # on a model id. An id-shaped rule cannot keep up with the naming: it read
      # gpt-5 as a reasoning model and gpt-5-mini and gpt-5-nano as ordinary
      # ones, and sent all three a temperature the API refuses for two of them.
      #
      # A model that refuses a custom temperature has the parameter left out
      # rather than rewritten to 1.0. Substituting a value silently answers a
      # different question than the caller asked; omitting it lets the model's
      # own default stand, which is what the API does for these models anyway.
      #
      # Where the registry says nothing the temperature is sent unchanged.
      # Silence is not a refusal, and a dropped parameter would be invisible.
      module Temperature
        module_function

        def normalize(temperature, model)
          return temperature if temperature.nil?
          return temperature unless model.respond_to?(:rejects_temperature?) && model.rejects_temperature?

          RubyLLM.logger.debug do
            "Model #{model.id} does not accept a custom temperature, removing it"
          end
          nil
        end
      end
    end
  end
end
