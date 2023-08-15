# frozen_string_literal: true

module Recog
  # A fingerprint that can be {#match matched} against a particular kind of
  # fingerprintable data, e.g. an HTTP `Server` header
  class Fingerprint
    require 'set'

    require 'recog/fingerprint_parse_error'
    require 'recog/fingerprint/regexp_factory'
    require 'recog/fingerprint/test'

    # A human readable name describing this fingerprint
    # @return (see #parse_description)
    attr_reader :name

    # Regular expression pulled from the {DB} xml file.
    #
    # @see #create_regexp
    # @return [Regexp] the Regexp to try when calling {#match}
    attr_reader :regex

    # Collection of indexes for capture groups created by {#match}
    #
    # @return (see #parse_params)
    attr_reader :params

    # Collection of example strings that should {#match} our {#regex}
    #
    # @return (see #parse_examples)
    attr_reader :tests

    # The line number of the XML entity in the source file for this
    # fingerprint.
    #
    # @return [Integer] The line number of this entity.
    attr_reader :line

    # @param xml [Nokogiri::XML::Element]
    # @param match_key [String] See Recog::DB
    # @param protocol [String] Protocol such as ftp, mssql, http, etc.
    # @param example_path [String] Directory path for fingerprint example files
    def initialize(xml, match_key = nil, protocol = nil, example_path = nil)
      @match_key = match_key
      @protocol = protocol&.downcase
      @name   = parse_description(xml)
      @regex  = create_regexp(xml)
      @line   = xml.line
      @params = {}
      @tests = []

      parse_examples(xml, example_path)
      parse_params(xml)
    end

    def output_diag_data(message, data, exception)
      $stderr.puts message
      $stderr.puts exception.inspect
      $stderr.puts "Length:   #{data.length}"
      $stderr.puts "Encoding: #{data.encoding}"
      $stderr.puts "Problematic data:\n#{data}"
      $stderr.puts "Raw bytes:\n#{data.pretty_inspect}\n"
    end

    # Attempt to match the given string.
    #
    # @param match_string [String]
    # @return [Hash,nil] Keys will be host, service, and os attributes
    def match(match_string)
      # match_string.force_encoding('BINARY') if match_string
      begin
        match_data = @regex.match(match_string)
      rescue Encoding::CompatibilityError
        begin
          # Replace invalid UTF-8 characters with spaces, just as DAP does.
          encoded_str = match_string.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
          match_data = @regex.match(encoded_str)
        rescue Exception => e
          output_diag_data('Exception while re-encoding match_string to UTF-8', match_string, e)
        end
      rescue Exception => e
        output_diag_data('Exception while running regex against match_string', match_string, e)
      end
      return if match_data.nil?

      result = { 'matched' => @name }
      replacements = {}
      @params.each_pair do |k, v|
        pos = v[0]
        if pos == 0
          # A match offset of 0 means this param has a hardcoded value
          result[k] = v[1]
          # if this value uses interpolation, note it for handling later
          v[1].scan(/\{([^\s{}]+)\}/).flatten.each do |replacement|
            replacements[k] ||= Set[]
            replacements[k] << replacement
          end
        else
          # A match offset other than 0 means the value should come from
          # the corresponding match result index
          result[k] = match_data[pos]
        end
      end

      # Use the protocol specified in the XML database if there isn't one
      # provided as part of this fingerprint.
      result['service.protocol'] = @protocol if @protocol && !(result['service.protocol'])

      result['fingerprint_db'] = @match_key if @match_key

      # for everything identified as using interpolation, do so
      replacements.each_pair do |replacement_k, replacement_vs|
        replacement_vs.each do |replacement|
          if result[replacement]
            result[replacement_k] = result[replacement_k].gsub(/\{#{replacement}\}/, result[replacement])
          else
            # if the value uses an interpolated value that does not exist, in general this could be
            # very bad, but over time we have allowed the use of regexes with
            # optional captures that are then used for parts of the asserted
            # fingerprints.  This is frequently done for optional version
            # strings.  If the key in question is cpe23 and the interpolated
            # value we are trying to replace is version related, use the CPE
            # standard of '-' for the version, otherwise raise and exception as
            # this code currently does not handle interpolation of undefined
            # values in other cases.
            raise "Invalid use of nil interpolated non-version value #{replacement} in non-cpe23 fingerprint param #{replacement_k}" unless replacement_k =~ (/\.cpe23$/) && replacement =~ (/\.version$/)

            result[replacement_k] = result[replacement_k].gsub(/\{#{replacement}\}/, '-')

          end
        end
      end

      # After performing interpolation, remove temporary keys from results
      result.each_pair do |k, _|
        result.delete(k) if k.start_with?('_tmp.')
      end

      result
    end

    # Ensure all the {#params} are valid
    #
    # @yieldparam status [Symbol] One of `:warn`, `:fail`, or `:success` to
    #   indicate whether a param is valid
    # @yieldparam message [String] A human-readable string explaining the
    #   `status`
    def verify_params
      return if params.empty?

      params.each do |param_name, pos_value|
        pos, value = pos_value
        if pos > 0 && !value.to_s.empty?
          yield :fail, "'#{@name}'s #{param_name} is a non-zero pos but specifies a value of '#{value}'"
        elsif pos == 0 && value.to_s.empty?
          yield :fail, "'#{@name}'s #{param_name} is not a capture (pos=0) but doesn't specify a value"
        end
      end
    end

    # Ensure all the {#tests} actually match the fingerprint and return the
    # expected capture groups.
    #
    # @yieldparam status [Symbol] One of `:warn`, `:fail`, or `:success` to
    #   indicate whether a test worked
    # @yieldparam message [String] A human-readable string explaining the
    #   `status`
    def verify_tests(&block)
      # look for the presence of test cases
      if tests.size == 0
        yield :warn, "'#{@name}' has no test cases"
        return
      end

      # make sure each test case passes
      tests.each do |test|
        result = match(test.content)
        if result.nil?
          yield :fail, "'#{@name}' failed to match #{test.content.inspect} with #{@regex}'"
          next
        end

        message = test
        status = :success
        # Ensure that all the attributes as provided by the example were parsed
        # out correctly and match the capture group values we expect.
        test.attributes.each do |k, v|
          next if k == '_encoding'
          next if k == '_filename'

          next unless !result.key?(k) || result[k] != v

          message = "'#{@name}' failed to find expected capture group #{k} '#{v}'. Result was #{result[k]}"
          status = :fail
          break
        end
        yield status, message
      end

      # make sure there are capture groups for all params that use them
      verify_tests_have_capture_groups(&block)
    end

    # For fingerprints that specify parameters that are defined by
    # capture groups, ensure that each parameter has at least one test
    # that defines an attribute to test for the correct capture of that
    # parameter.
    #
    # @yieldparam status [Symbol] One of `:warn`, `:fail`, or `:success` to
    #   indicate whether a test worked
    # @yieldparam message [String] A human-readable string explaining the
    #   `status`
    def verify_tests_have_capture_groups
      capture_group_used = {}
      unless params.empty?
        # get a list of parameters that are defined by capture groups
        params.each do |param_name, pos_value|
          pos, value = pos_value
          capture_group_used[param_name] = false if pos > 0 && value.to_s.empty?
        end
      end

      # match up the fingerprint parameters with test attributes
      tests.each do |test|
        test.attributes.each do |k, _v|
          capture_group_used[k] = true if capture_group_used.key?(k)
        end
      end

      # alert on untested parameters unless they are temporary
      capture_group_used.each do |param_name, param_used|
        next unless !param_used && !param_name.start_with?('_tmp.')

        message = "'#{@name}' is missing an example that checks for parameter '#{param_name}' " \
                  'which is derived from a capture group'
        yield :fail, message
      end
    end

    private

    # @param xml [Nokogiri::XML::Element]
    # @return [Regexp]
    def create_regexp(xml)
      pattern = xml['pattern']
      flags   = xml['flags'].to_s.split(',')
      RegexpFactory.build(pattern, flags)
    end

    # @param xml [Nokogiri::XML::Element]
    # @return [String] Contents of the source XML's `description` tag
    def parse_description(xml)
      element = xml.xpath('description')
      element.empty? ? '' : element.first.content.to_s.gsub(/\s+/, ' ').strip
    end

    # @param xml [Nokogiri::XML::Element]
    # @param example_path [String] Directory path for fingerprint example files
    # @return [void]
    def parse_examples(xml, example_path)
      elements = xml.xpath('example')

      elements.each do |elem|
        # convert nokogiri Attributes into a hash of name => value
        attrs = elem.attributes.values.reduce({}) { |a, e| a.merge(e.name => e.value) }
        if attrs['_filename']
          contents = ''
          filename = attrs['_filename']
          fn = File.expand_path(File.join(example_path, filename))
          unless fn.start_with?(File.expand_path(example_path) + File::Separator)
            raise FingerprintParseError.new("an example specifies an illegal file path '#{filename}'",
                                            @line)
          end

          File.open(fn, 'rb') do |file|
            contents = file.read
            contents.force_encoding(Encoding::ASCII_8BIT)
          end
          @tests << Test.new(contents, attrs)
        else
          @tests << Test.new(elem.content, attrs)
        end
      end

      nil
    end

    # @param xml [Nokogiri::XML::Element]
    # @return [Hash<String,Array>] Keys are things like `"os.name"`, values are a two
    #   element Array. The first element is an index for the capture group that returns
    #   that thing. If the index is 0, the second element is a static value for
    #   that thing; otherwise it is undefined.
    def parse_params(xml)
      @params = {}.tap do |h|
        xml.xpath('param').each do |param|
          name  = param['name']
          pos   = param['pos'].to_i
          value = param['value'].to_s
          h[name] = [pos, value]
        end
      end

      nil
    end
  end
end
