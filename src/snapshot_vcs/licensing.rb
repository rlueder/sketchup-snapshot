# frozen_string_literal: true

module SnapshotVCS
  # Entitlement, as reported by Extension Warehouse.
  #
  # There is no trial to build here and no keys to issue. Trimble runs the
  # trial, sells the licence and tracks who has one; this module asks what the
  # answer is and the rest of the plugin reacts.
  #
  # Two rules shape everything below:
  #
  #   * A licence check must never cost a user their work. Anything that reads
  #     or recovers what they already saved stays available forever, and a
  #     failed check fails *open* — a network hiccup that blocks a paying
  #     customer costs far more than the handful of people it lets through.
  #   * It must never run on the UI tick. Since SketchUp 2025 the automatic
  #     licence fetch is deliberately skipped during startup, and the API's own
  #     advice is to check when the user interacts with the extension.
  module Licensing
    # The Extension Warehouse UUID for this extension, issued when the listing
    # is created. Empty until then — and an empty id means unrestricted, so
    # development and source builds are never gated.
    EXTENSION_ID = ''

    STORE_URL = 'https://extensions.sketchup.com/'

    Entitlement = Struct.new(:state, :licensed, :trial, :days_remaining, keyword_init: true) do
      def licensed?
        !!licensed
      end

      def trial?
        !!trial
      end

      def to_h
        { 'state' => state.to_s, 'licensed' => licensed?, 'trial' => trial?,
          'days_remaining' => days_remaining }
      end
    end

    class << self
      # Overridable so the test suite can drive every licence state.
      attr_writer :extension_id

      def extension_id
        @extension_id.nil? ? EXTENSION_ID : @extension_id
      end

      def reset!
        @extension_id = nil
      end

      def configured?
        !extension_id.to_s.strip.empty?
      end

      # Deliberately not memoised: the API asks callers not to hold on to a
      # licence, because the state changes the moment somebody buys.
      #
      # @return [Entitlement]
      def entitlement
        return unrestricted(:unlisted) unless configured?
        return unrestricted(:unsupported) unless available?

        license = Sketchup::Licensing.get_extension_license(extension_id)
        Entitlement.new(
          state: state_name(license),
          licensed: license.licensed?,
          trial: trial?(license),
          days_remaining: days_remaining(license)
        )
      rescue StandardError => e
        Log.error("licence check failed: #{e.message}")
        unrestricted(:unknown)
      end

      def licensed?
        entitlement.licensed?
      end

      def open_store
        UI.openURL(STORE_URL)
        true
      rescue StandardError => e
        Log.error("could not open the store: #{e.message}")
        false
      end

      private

      def available?
        defined?(Sketchup::Licensing) &&
          Sketchup::Licensing.respond_to?(:get_extension_license)
      end

      def unrestricted(reason)
        Entitlement.new(state: reason, licensed: true, trial: false, days_remaining: nil)
      end

      def trial?(license)
        license.state == Sketchup::Licensing::TRIAL
      rescue StandardError
        false
      end

      def days_remaining(license)
        value = license.days_remaining
        value.is_a?(Numeric) && value >= 0 ? value.to_i : nil
      rescue StandardError
        nil
      end

      def state_name(license)
        constants = {
          Sketchup::Licensing::LICENSED => :licensed,
          Sketchup::Licensing::EXPIRED => :expired,
          Sketchup::Licensing::TRIAL => :trial,
          Sketchup::Licensing::TRIAL_EXPIRED => :trial_expired,
          Sketchup::Licensing::NOT_LICENSED => :not_licensed
        }
        constants.fetch(license.state, :unknown)
      rescue StandardError
        :unknown
      end
    end
  end
end
