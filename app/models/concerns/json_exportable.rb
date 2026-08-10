module JsonExportable
    extend ActiveSupport::Concern
  
  
    class_methods do
      def json_exportable_path
        File.join(Rails.root, "json_exportable", "#{self.name.pluralize.underscore}.json")
      end
  
      def json_export!
        data = self.all.map(&:attributes)
        File.write(json_exportable_path, JSON.pretty_generate(data))
      end
  
      def json_import!(options = {})
        options = {
          purge: false
        }.merge(options)
        self.destroy_all if options[:purge]
        JSON.parse(File.read(json_exportable_path)).each do |line|
          self.build(line).save!(validate: false)
        end
      end
  
    end
  end
  