# coding: utf-8

require 'multi_json'

module Guard
  class Jasmine

    # The Jasmine runner handles the execution of the spec through the PhantomJS binary,
    # evaluates the JSON response from the PhantomJS Script `run_jasmine.coffee`,
    # writes the result to the console and triggers optional system notifications.
    #
    module Runner
      class << self

        # Run the supplied specs.
        #
        # @param [Array<String>] paths the spec files or directories
        # @param [Hash] options the options for the execution
        # @option options [String] :jasmine_url the url of the Jasmine test runner
        # @option options [String] :phantomjs_bin the location of the PhantomJS binary
        # @option options [Boolean] :notification show notifications
        # @option options [Boolean] :hide_success hide success message notification
        # @return [Boolean, Array<String>] the status of the run and the failed files
        #
        def run(paths, options = { })
          return [false, []] if paths.empty?

          notify_start_message(paths)

          results = paths.inject([]) do |results, file|
            results << evaluate_result(run_jasmine_spec(file, options), file, options)

            results
          end.compact

          [response_status_for(results), failed_paths_from(results)]
        end

        private

        # Shows a notification in the console that the runner starts.
        #
        # @param [Array<String>] paths the spec files or directories
        #
        def notify_start_message(paths)
          message = if paths == ['spec/javascripts']
                      'Run all Jasmine suites'
                    else
                      "Run Jasmine suite#{ paths.size == 1 ? '' : 's' } #{ paths.join(' ') }"
                    end

          Formatter.info(message, :reset => true)
        end

        # Returns the failed spec file names.
        #
        # @param [Array<Object>] results the spec runner results
        # @return [Array<String>] the list of failed spec files
        #
        def failed_paths_from(results)
          results.map { |r| !r['passed'] ? r['file'] : nil }.compact
        end

        # Returns the response status for the given result set.
        #
        # @param [Array<Object>] results the spec runner results
        # @return [Boolean] whether it has passed or not
        #
        def response_status_for(results)
          results.none? { |r| r.has_key?('error') || !r['passed'] }
        end

        # Run the Jasmine spec by executing the PhantomJS script.
        #
        # @param [String] path the path of the spec
        #
        def run_jasmine_spec(file, options)
          suite = jasmine_suite(file, options)
          Formatter.info("Run Jasmine suite at #{ suite }")
          IO.popen(phantomjs_command(options) + ' ' + suite)
        end

        # Get the PhantomJS binary and script to execute.
        #
        # @param [Hash] options the options for the execution
        # @return [String] the command
        #
        def phantomjs_command(options)
          options[:phantomjs_bin] + ' ' + phantomjs_script
        end

        # Get the Jasmine test runner URL with the appended suite name
        # that acts as the spec filter.
        #
        # @param [Hash] options the options for the execution
        # @return [String] the Jasmine url
        #
        def jasmine_suite(file, options)
          options[:jasmine_url] + query_string_for_suite(file)
        end

        # Get the PhantomJS script that executes the spec and extracts
        # the result from the headless DOM.
        #
        # @return [String] the path to the PhantomJS script
        #
        def phantomjs_script
          File.expand_path(File.join(File.dirname(__FILE__), 'phantomjs', 'run-jasmine.coffee'))
        end

        # The suite name must be extracted from the spec that
        # will be run. This is done by parsing from the head of
        # the spec file until the first `describe` function is
        # found.
        #
        # @param [String] file the spec file
        # @return [String] the suite name
        #
        def query_string_for_suite(file)
          return '' if file == 'spec/javascripts'

          query_string = ''

          File.foreach(file) do |line|
            if line =~ /describe\s*[("']+(.*?)["')]+/
              query_string = "?spec=#{ $1 }"
              break
            end
          end

          URI.encode(query_string)
        end

        # Evaluates the JSON response that the PhantomJS script
        # writes to stdout. The results triggers further notification
        # actions.
        #
        # @param [String] output the JSON output the spec run
        # @param [String] file the file name of the spec
        # @param [Hash] options the options for the execution
        # @return [Hash] the suite result
        #
        def evaluate_result(output, file, options)
          json = output.read

          begin
            result = MultiJson.decode(json)
            output.close

            if result['error']
              notify_runtime_error(result, options)
            else
              result['file'] = file
              notify_spec_result(result, options)
            end

            result

          rescue Exception => e
            Formatter.error("Cannot decode JSON from PhantomJS runner: #{ e.message }")
            Formatter.error('Please report an issue at: https://github.com/netzpirat/guard-jasmine/issues')
            Formatter.error(json)
          end
        end

        # Notification when a system error happens that
        # prohibits the execution of the Jasmine spec.
        #
        # @param [Hash] the suite result
        # @param [Hash] options the options for the execution
        # @option options [Boolean] :notification show notifications
        #
        def notify_runtime_error(result, options)
          message = "An error occurred: #{ result['error'] }"
          Formatter.error(message)
          Formatter.notify(message, :title => 'Jasmine error', :image => :failed, :priority => 2) if options[:notification]
        end

        # Notification about a spec run, success or failure,
        # and some stats.
        #
        # @param [Hash] result the suite result
        # @param [Hash] options the options for the execution
        # @option options [Boolean] :notification show notifications
        # @option options [Boolean] :hide_success hide success message notification
        #
        def notify_spec_result(result, options)
          specs    = result['stats']['specs']
          failures = result['stats']['failures']
          time     = result['stats']['time']
          plural   = failures == 1 ? '' : 's'

          message = "#{ specs } specs, #{ failures } failure#{ plural }\nin #{ time } seconds"

          if failures != 0
            notify_specdoc(result, message, options)
            Formatter.notify(message, :title => 'Jasmine suite failed', :image => :failed, :priority => 2) if options[:notification]
          else
            Formatter.success(message)
            Formatter.notify(message, :title => 'Jasmine suite passed') if options[:notification] && !options[:hide_success]
          end
        end

        # Specdoc like formatting of the result.
        #
        # @param [Hash] result the suite result
        # @param [String] stats the status information
        # @option options [Boolean] :hide_success hide success message notification
        #
        def notify_specdoc(result, stats, options)
          result['suites'].each do |suite|
            Formatter.suite_name("➥ #{ suite['description'] }")

            suite['specs'].each do |spec|
              if spec['passed']
                Formatter.success(" ✔ #{ spec['description'] }") if !options[:hide_success]
              else
                Formatter.spec_failed(" ✘ #{ spec['description'] }")
                Formatter.spec_failed("   ➤ #{ format_error_message(spec['error_message'], false) }")
                Formatter.notify("#{ spec['description'] }: #{ format_error_message(spec['error_message'], true) }",
                                 :title    => 'Jasmine spec failed',
                                 :image    => :failed,
                                 :priority => 2) if options[:notification]
              end
            end
          end

          Formatter.info(stats)
        end

        # Formats the error message.
        #
        # Known message styles:
        #
        # - {message} in http.*assets/{spec}?body=\d ({line})
        #
        # @param [String] message the error message
        # @param [Boolean] short show a short version of the message
        # @return [String] the cleaned error message
        #
        def format_error_message(message, short)
          if message =~ /(.*?) in http.+?assets\/(.*)\?body=\d+\s\((line\s\d+)/
            short ? $1 : "#{ $1 } in #{ $2 } on #{ $3 }"
          else
            message
          end
        end

      end
    end
  end
end
