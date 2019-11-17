require_relative 'yaml_extend/version'

require 'yaml'
require 'deep_merge/rails_compat'

require_relative 'yaml_extend/yaml_extend_helper'

require_relative 'custom_errors/invalid_key_type_error'

#
# Extending the YAML library to allow to inherit from another YAML file(s)
#

module YAML
  # default path in the yaml file where the files to inherit from are defined
  DEFAULT_INHERITANCE_KEY = 'extends'
  @@ext_load_key = nil
  #
  # Set a custom inheritance key globally once.
  # So you don't need to specify it on every call of ext_load_file()
  #
  # @param key [String|Array<String>|nil] the key in the yaml file, containing the file strings to extend from. Set nil or call #reset_load_key to reset the key.
  def self.ext_load_key=(key)
    if key.is_a?(String) || key.is_a?(Array) || key.nil?
      @@ext_load_key = key
    else
      raise "Parameter 'key' must be of type String or Array<String> or nil"
    end
  end

  #
  # Reset the ext_load_key and use the default settings
  #
  def self.reset_load_key()
    @@ext_load_key = nil
  end
  #
  # Extended variant of the #load_file method by providing the 
  # ability to inherit from other YAML file(s)
  #
  # @param yaml_path [String] the path to the yaml file to be loaded
  # @param inheritance_key [String|Array] The key used in the yaml file to extend from another YAML file. Use an Array if you want to use a tree structure key like "options.extends" => ['options','extends']
  # @param extend_existing_arrays [Boolean] extend existing arrays instead of replacing them
  # @param config [Hash] a hash to be merged into the result, usually only recursivly called by the method itself
  #
  # @return [Hash] the resulting yaml config 
  #
  def self.ext_load_file(yaml_path, inheritance_key=nil, extend_existing_arrays=true, config = {})
    if inheritance_key.nil?
      inheritance_key = @@ext_load_key || DEFAULT_INHERITANCE_KEY
    end
    tree = build_tree yaml_path, inheritance_key
    pp tree
    tree2order tree, :base2derived
    total_config ||= {}
    yaml_path = YAML.make_absolute_path yaml_path
    super_config = YamlExtendHelper.encode_booleans YAML.load_file(File.open(yaml_path))
    super_inheritance_files = yaml_value_by_key inheritance_key, super_config
    delete_yaml_key inheritance_key, super_config # we don't merge the super inheritance keys into the base yaml
    puts "merging #{yaml_path} into existing config"
    puts " source (new base)=#{super_config}"
    puts " dest   (existing)=#{config}"
    merged_config = config.clone.deeper_merge(super_config, extend_existing_arrays: extend_existing_arrays)
    puts "result            =#{merged_config}"
    if super_inheritance_files && super_inheritance_files != ''
      super_inheritance_files = [super_inheritance_files] unless super_inheritance_files.is_a? Array # we support strings as well as arrays of type string to extend from
      super_inheritance_files.each_with_index do |super_inheritance_file, index|
        super_config_path = File.dirname(yaml_path) + '/' + super_inheritance_file
        total_config = YamlExtendHelper.encode_booleans YAML.ext_load_file(super_config_path, inheritance_key, extend_existing_arrays, total_config.deeper_merge(merged_config, extend_existing_arrays: extend_existing_arrays))
      end
      YamlExtendHelper.decode_booleans total_config
    else
      delete_yaml_key inheritance_key, merged_config
      YamlExtendHelper.decode_booleans merged_config
    end
  end

  private

  # some logic to ensure absolute file inheritance as well as 
  # relative file inheritance in yaml files  
  def self.make_absolute_path(file_path)
    private_class_method
    return file_path if YAML.absolute_path?(file_path) && File.exist?(file_path)
    base_path = File.dirname(caller_locations[1].path)
    return base_path + '/' + file_path if File.exist? base_path + '/' + file_path # relative path from yaml file
    return Dir.pwd + '/' + file_path if File.exist? Dir.pwd + '/' + file_path # relative path from project
    error_message = "Can not find absolute path of '#{file_path}'"
    unless YAML.absolute_path? file_path
      error_message += "\nAlso tried:\n- #{base_path + '/' + file_path}\n"\
                       "- #{Dir.pwd + '/' + file_path}\n"
    end
    raise error_message
  end

  def self.absolute_path?(path)
    private_class_method
    path.start_with?('/') || # unix like
      (path.length >= 3 && path[1] == ':') # ms windows
  end

  # Return the value of the corresponding key
  # @param key [String|Array]
  def self.yaml_value_by_key(key, config)
    return config[key] if key.is_a? String
    if valid_key_type? key
      cfg_copy = config.clone
      key.each do |key|
        if cfg_copy.nil?
          return
        elsif valid_key_type? key
          cfg_copy = cfg_copy[key]
        end
      end
      cfg_copy
    end
  end

  def self.valid_key_type?(key)
    key.is_a?(Array) || key.is_a?(String) ||
        raise(InvalidKeyTypeError,"Invalid key of type '#{key.class.name}'. Valid types are String and Array.")
  end

  def self.delete_yaml_key(key, config)
    return config.delete(key) if key.is_a? String
    cfg_ref = config
    last_ref = nil
    key.each do |key|
      if valid_key_type?(key) && !cfg_ref[key].nil?
        last_ref = cfg_ref
        cfg_ref = cfg_ref[key] unless cfg_ref.nil?
      end
    end
    last_ref.delete key.last unless last_ref.nil?
  end

  # builds the tree from 'most derived' to the base classes
  # used to allow doing the merge direction from base -> derived
  # tree is a nested hash of key, values with
  # - key = yaml path
  # - value = array of yaml children hashes
  def self.build_tree(yaml_path, inheritance_key=nil, tree = {})
    if inheritance_key.nil?
      inheritance_key = @@ext_load_key || DEFAULT_INHERITANCE_KEY
    end
    yaml_path = YAML.make_absolute_path yaml_path
    tree[yaml_path]=[]
    super_config = YAML.load_file(File.open(yaml_path))
    super_inheritance_files = yaml_value_by_key inheritance_key, super_config
    if super_inheritance_files && super_inheritance_files != ''
      super_inheritance_files = [super_inheritance_files] unless super_inheritance_files.is_a? Array # we support strings as well as arrays of type string to extend from
      super_inheritance_files.each_with_index do |super_inheritance_file, index|
        super_config_path = File.dirname(yaml_path) + '/' + super_inheritance_file
        tree[yaml_path]<<{}
        YAML.build_tree(super_config_path, inheritance_key, tree[yaml_path][index])
      end
    end
    return tree
  end

  # given a yaml tree, determine the order of merging
  # order:
  # - :base2derived
  # more options could be possible. E.g. the default yaml_extend method could also use this
  def self.tree2order(tree, order=:base2derived, ordered_list = [])
    raise "only :base2derived order is supported" unless order==:base2derived
    raise "unexpected hash size != 1" unless tree.length==1
    this,supers = tree.first
    ordered_list<<this
    puts "added #{this} to list"
    supers.each_with_index do |super_tree, index|
      tree2order super_tree, order, ordered_list
    end
  end

end
