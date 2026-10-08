# frozen_string_literal: true

module RubyLLM
  module Model
    # Keeps the prices only the registry states across a refresh.
    #
    # models.dev and the provider listings win every price they state, but
    # neither publishes everything a provider's pricing page does - models.dev
    # has no 1-hour cache write, for one. Replacing a model's pricing wholesale
    # would drop such a price on every refresh and leave the cost of the calls
    # that pay it unknown. A price absent from the fresh sources is weak
    # evidence, as an unlisted model is: the registry's value is kept until a
    # source states another.
    #
    # Registries come lowest precedence first: the bundled `models.json`, where
    # a release records prices from the providers' pages, then the one in use.
    # The one in use alone is not enough - an app that publishes its refreshed
    # registry and refreshes from it again would have lost the price on the
    # first refresh and never get it back.
    module RegistryPrices
      module_function

      def apply(models, *registries)
        indexes = registries.map { |registry| registry.to_h { |model| [key(model), model] } }

        models.map do |model|
          pricing = pricing_for(model, indexes)
          pricing == model.pricing.to_h ? model : Info.new(model.to_h.merge(pricing:))
        end
      end

      # The model's fresh pricing over what the registries knew, each newer
      # source winning what it states.
      def pricing_for(model, indexes)
        known = indexes.filter_map { |index| index[key(model)]&.pricing&.to_h }
        (known << model.pricing.to_h).reduce { |kept, fresher| Utils.deep_merge(kept, fresher) }
      end

      def key(model) = "#{model.provider}:#{model.id}"
    end
  end
end
