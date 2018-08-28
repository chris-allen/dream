require "berkshelf"
require "dream-ops/utils/zip"
require 'fileutils'

module DreamOps
  class BaseDeployer
    class << self
      #
      # @macro deployer_method
      #   @method $1(*args)
      #     Create a deployer method for the declaration
      #
      def deployer_method(name)
        class_eval <<-EOH, __FILE__, __LINE__ + 1
          def #{name}(*args)
            raise AbstractFunction,
              "##{name} must be implemented on \#{self.class.name}!"
          end
        EOH
      end
    end

    # This method MUST be implemented by subclasses.
    #
    # @return [Hash]
    #   a hash containing cookbooks that need to be built/updated
    #   and deploy targets
    #
    #   Example:
    #     {
    #       :cookbooks => [
    #         {
    #           :bucket => "chef-app",
    #           :cookbook_key => "chef-app-dev.zip",
    #           :sha_key => "chef-app-dev_SHA.txt",
    #           :name => "chef-app",
    #           :path => "./chef",
    #           :local_sha => "7bfa19491170563f422a321c144800f4435323b1",
    #           :remote_sha => ""
    #         }
    #       ],
    #       deploy_targets: [
    #         #<Hash>,
    #         #<Hash>
    #       ]
    #     }
    deployer_method :analyze

    # This method MUST be implemented by subclasses.
    #
    # @param [Hash] cookbook
    #   a hash containing the cookbook details
    deployer_method :deploy_cookbook


    # This method MUST be implemented by subclasses.
    #
    # @param [Hash] target
    #   a hash containing the deploy target details
    deployer_method :deploy_target

    # It may turn out that cookbook building will be different for different
    # deployments, but for now all deployments will build them the same way.
    def build_cookbook(cookbook)
      berksfile = Berkshelf::Berksfile.from_file(File.join(cookbook[:path], "Berksfile"))
      berksfile.vendor("berks-cookbooks")

      File.open("berks-cookbooks/Berksfile", 'w') { |file|
        file.write("source \"https://supermarket.chef.io\"\n\n")
        file.write("cookbook \"#{cookbook[:name]}\", path: \"./#{cookbook[:name]}\"")
      }
      zf = ZipFileGenerator.new("berks-cookbooks", cookbook[:cookbook_key])
      zf.write
    end

    def cleanup_cookbooks(cookbooks)
      cookbooks.each do |cookbook|
        File.delete(cookbook[:cookbook_key])
        FileUtils.remove_dir("berks-cookbooks")
      end
    end

    def deploy(*args)
      # Find unique cookbooks and deploy targets
      result = analyze(args)

      # Build each unique cookbook once in case it's used by more than one app
      result[:cookbooks].each do |cookbook|
        DreamOps.ui.info "...Building cookbook [#{cookbook[:name]}]"
        build_cookbook(cookbook)

        DreamOps.ui.info "...Deploying cookbook [#{cookbook[:name]}]"
        deploy_cookbook(cookbook)
      end
      cleanup_cookbooks(result[:cookbooks])

      # Update cookbooks if needed and deploy to all targets
      deploy_success = true
      deploy_threads = []
      result[:deploy_targets].each do |target|
        deploy_threads << Thread.new { deploy_target(target, result[:cookbooks]) }
      end
      deploy_threads.each do |t|
        begin
          t.join
        rescue DreamOps::DreamOpsError
          DreamOps.ui.error "#{$!}"
          deploy_success = deploy_success && false
        end
      end

      # If ANY deploy threads failed, exit with failure
      exit(1) if !deploy_success
    end
  end
end