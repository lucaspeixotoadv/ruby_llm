# frozen_string_literal: true

require 'json'
require 'strscan'

module RubyLLM
  # The value a JSON document holds so far, read from a prefix of it -- what a
  # structured response (`Chat#with_schema`) says while it is still streaming.
  #
  # A string shows every character already complete: an escape or a surrogate
  # pair cut at the end shows once its last character arrives. Anything that
  # could still change -- a number, a literal, an object key -- shows only once
  # it is whole, and a key shows together with the beginning of its value. So
  # what a prefix shows is only ever added to as the document grows, and the
  # whole document reads as `JSON.parse` reads it.
  #
  # A prefix that no JSON document begins with raises `ParseError`.
  module PartialJSON
    class ParseError < JSON::ParserError; end

    # @param text [String] the beginning of a JSON document
    # @return [Object, nil] what it holds so far; nil while no value has begun
    def self.parse(text)
      Reader.new(text).document
    end

    # Reads one prefix. Each `read_*` returns the value and whether it is
    # complete; `NOTHING` is a value not yet begun.
    class Reader
      NOTHING = Object.new.freeze
      ESCAPES = { '"' => '"', '\\' => '\\', '/' => '/', 'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r",
                  't' => "\t" }.freeze
      NUMBER = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/
      NUMBER_PREFIX = /\A-?\d*(?:\.\d*)?(?:[eE][+-]?\d*)?\z/
      LITERALS = { 'true' => true, 'false' => false, 'null' => nil }.freeze
      HIGH_SURROGATES = (0xD800..0xDBFF)
      LOW_SURROGATES = (0xDC00..0xDFFF)

      def initialize(text)
        @scanner = StringScanner.new(text)
      end

      def document
        value, complete = read_value
        return (value.equal?(NOTHING) ? nil : value) unless complete

        skip_space
        fail_at('unexpected content after the document') unless @scanner.eos?
        value
      end

      private

      def read_value
        skip_space
        return [NOTHING, false] if @scanner.eos?

        case @scanner.peek(1)
        when '{' then read_object
        when '[' then read_array
        when '"' then read_string
        when '-', /\d/ then read_number
        else read_literal
        end
      end

      def read_object
        @scanner.getch
        object = {}
        loop do
          skip_space
          return [object, false] if @scanner.eos?
          return [object, true] if @scanner.skip('}')

          return [object, false] unless member_follows?(object.empty?)

          key, complete = read_key
          return [object, false] unless complete

          value, complete = read_member_value
          object[key] = value unless value.equal?(NOTHING)
          return [object, false] unless complete
        end
      end

      def read_key
        skip_space
        return [nil, false] if @scanner.eos?

        fail_at('expected an object key') unless @scanner.peek(1) == '"'
        read_string
      end

      def read_member_value
        skip_space
        return [NOTHING, false] if @scanner.eos?

        fail_at("expected ':'") unless @scanner.skip(':')
        read_value
      end

      def read_array
        @scanner.getch
        array = []
        loop do
          skip_space
          return [array, false] if @scanner.eos?
          return [array, true] if @scanner.skip(']')

          return [array, false] unless member_follows?(array.empty?)

          value, complete = read_value
          array << value unless value.equal?(NOTHING)
          return [array, false] unless complete
        end
      end

      # Whether a member follows: before every member but the first, a comma.
      # False while the prefix ends before the member begins.
      def member_follows?(first)
        return true if first

        fail_at("expected ','") unless @scanner.skip(',')
        skip_space
        !@scanner.eos?
      end

      def read_string
        @scanner.getch
        string = +''
        loop do
          string << @scanner.scan(/[^"\\]+/).to_s
          return [string, false] if @scanner.eos?
          return [string, true] if @scanner.skip('"')

          @scanner.getch
          character = read_escape
          return [string, false] if character.nil?

          string << character
        end
      end

      # The character an escape stands for; nil while the prefix ends inside it.
      def read_escape
        return nil if @scanner.eos?

        letter = @scanner.getch
        return ESCAPES.fetch(letter) if ESCAPES.key?(letter)

        fail_at("invalid escape '\\#{letter}'") unless letter == 'u'
        read_unicode
      end

      def read_unicode
        code = read_code_unit
        return nil if code.nil?
        return character(code) unless HIGH_SURROGATES.cover?(code)
        return nil if '\\u'.start_with?(@scanner.rest)

        fail_at('unpaired surrogate') unless @scanner.skip('\\u')
        low = read_code_unit
        return nil if low.nil?

        fail_at('unpaired surrogate') unless LOW_SURROGATES.cover?(low)

        character(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00))
      end

      def character(code)
        fail_at('unpaired surrogate') if LOW_SURROGATES.cover?(code)

        [code].pack('U')
      end

      # Four hex digits; nil while the prefix ends inside them.
      def read_code_unit
        hex = @scanner.scan(/\h{4}/)
        return hex.to_i(16) if hex
        return nil if @scanner.rest.match?(/\A\h{0,3}\z/)

        fail_at('invalid unicode escape')
      end

      # A number shows once something follows it: until then, the prefix may
      # end in the middle of it.
      def read_number
        return [NOTHING, false] if @scanner.rest.match?(NUMBER_PREFIX)

        number = @scanner.scan(NUMBER) or fail_at('invalid number')
        [number.match?(/[.eE]/) ? Float(number) : Integer(number, 10), true]
      end

      def read_literal
        LITERALS.each do |word, value|
          return [value, true] if @scanner.skip(word)
          return [NOTHING, false] if word.start_with?(@scanner.rest)
        end
        fail_at('unexpected character')
      end

      def skip_space
        @scanner.skip(/[ \t\n\r]*/)
      end

      def fail_at(problem)
        raise ParseError, "#{problem} at offset #{@scanner.pos}"
      end
    end
  end
end
