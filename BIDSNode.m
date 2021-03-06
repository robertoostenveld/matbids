classdef BIDSNode < matlab.mixin.Copyable % handle
    % 	Represents a single directory or other logical grouping within a
    %     BIDS project.
    %
    %     Args:
    %         path (str): The full path to the directory.
    %         config (str, list): One or more names of built-in configurations
    %             (e.g., 'bids' or 'derivatives') that specify the rules that apply
    %             to this node.
    %         root (BIDSNode): The node at the root of the tree the current node is
    %             part of.
    %         parent (BIDSNode): The parent of the current node.
    %         force_index (bool): Whether or not to forcibly index every file below
    %             this node, even if it fails standard BIDS validation.
    
    
    properties (SetAccess = protected)
        child_class_ = []
        child_entity_ = []
        entities_ = {}
        entities = struct
        layout = [];
        fpath
        hash
        config
        root
        parent
        available_entities = struct
        children = {}
        files = []
        variables = []
        force_index
    end
    
    properties(Dependent)
        root_path
        abs_path
    end
    
    methods
        
        function disp(obj)
            if isprop(obj, 'subjects')
                children = 'Subjects';
            elseif isprop(obj, 'sessions')
                children = 'Sessions';
            elseif isprop(obj, 'label')
                children = 'Dirs';
            else
                children = 'Children';
            end
            
            fprintf('Class: %s | Path: %s | %s: %d | Files: %d', class(obj), obj.fpath, children, numel(obj.children), numel(obj.files));
            if isprop(obj, 'label')
                fprintf(' | Label: %s', obj.label)
            end
            
            fns = fieldnames(obj.entities);
            if ~isempty(fns)
                fprintf(' | Entities: ');
                
                delim = ' | ';
                for i=1:numel(fns)
                    if i==numel(fns)
                        delim = '';
                    end
                    fprintf('%s: %s%s', fns{i}, num2str(obj.entities.(fns{i})), delim);
                end
            end
            fprintf('\n');
        end
        
        function obj = BIDSNode(fpath, config, varargin)
            p = inputParser;
            addRequired(p, 'fpath',@(x)validateattributes(x,{'char'},{'nonempty'}));
            addRequired(p, 'config', @(x)validateattributes(x,{'cell', 'Config'},{'nonempty'}));
            addOptional(p, 'layout', {}, @(x)validateattributes(x,{'cell', 'BIDSLayout'},{}));
            addOptional(p, 'root', {}, @(x)validateattributes(x,{'cell', 'BIDSNode'},{}));
            addOptional(p, 'parent', {}, @(x)validateattributes(x,{'cell', 'BIDSNode'},{}));
            addOptional(p, 'force_index', false, @(x)validateattributes(x,{'logical', 'double'},{'nonempty'}));
            
            parse(p, fpath, config, varargin{:});
            
            obj.fpath = p.Results.fpath;
            obj.config = cellify(p.Results.config);
            %cellfun( @(c) validateattributes(c, {'Config'}, {}), obj.config);
            
            obj.layout = p.Results.layout;
            %if iscell(obj.layout), obj.layout = {}; end
            
            obj.root = p.Results.root;
            %if iscell(obj.root), obj.root = {}; end
            
            obj.parent = p.Results.parent;
            %if iscell(obj.parent), obj.parent = {}; end
            
            obj.force_index = p.Results.force_index;
            
            
            % Workaround to deal with fact that child classes cannot
            % overwrite inherited properties before object creation in
            % constructor
            props = {'my_child_class_', 'my_child_entity_', 'my_entities_'};
            for i = props
                my_prop = i{1};
                prop = my_prop(4:end);
                
                if isprop(obj, my_prop)
                    obj.(prop) = obj.(my_prop);
                end
            end
            
            % Check for additional config file in directory
            layout_file = obj.layout.config_filename;
            config_file = fullfile(obj.abs_path, layout_file, '.json');
            
            if exist(config_file, 'file') == 2
                cfg = Config.load(config_file);
                obj.config{end+1}=(cfg);
            end
            
            % Consolidate all entities
            obj.update_entities();
            
            % Extract local entity values
            obj.extract_entities();
            
            % Do subclass-specific setup
            % Bug in pybids? moved to end
            %obj.setup()
            
            % Append to layout's master list of nodes
            obj.layout.nodes{end+1} = obj;
            
            % Index files and create child nodes
            obj.index();
            
            % Do subclass-specific setup
            % Bug in pybids? Moved to here to allow getting children after
            % creation
            obj.setup();
            
        end
    end
    
    methods % (Access = protected)
        function setup(obj)
        end
    end
    
    methods
        
        function abs_path = get.abs_path(obj)
            abs_path = path_join(obj.root_path, obj.fpath);
        end
        
        function root_path = get.root_path(obj)
            if isempty(obj.root)
                % if I am root
                root_path = obj.fpath;
            else
                % if I am a child node
                root_path = obj.root.fpath;
            end
        end
        
        function layout = get.layout(obj)
            if isempty(obj.root)
                % if I am root
                layout = obj.layout;
            else
                % if I am a child node
                layout = obj.root.layout;
            end
        end
        
        function index(obj)
            % Index all files/directories below the current BIDSNode. """
            
            [dirnames, filenames] = list_dir(obj.fpath);
            
            %
            [comp ~] = ismember(filenames, obj.layout.config_filename);
            
            % fastest
            comp = cellfun(@(x) strcmp(x, obj.layout.config_filename), filenames);
            
            filenames(comp)=[];
            
            for f=1:numel(filenames)
                f=filenames{f};
                abs_fn = fullfile(obj.fpath, f);
                %disp(sprintf('Processing file %s', f))
                
                % Skip files that fail validation, unless forcibly indexing
                if ~obj.force_index %&& ~layout._validate_file(abs_fn):
                    continue
                end
                bf = BIDSFile(abs_fn, obj);
                
                % Extract entity values
                match_vals = struct;
                
                entities_ = struct2cell(obj.available_entities);
                for e=1:numel(entities_)
                    e=entities_{e};
                    m = e.match_file(bf);
                    
                    if ~isempty(m)
                        match_vals.(e.name) = {e, m};
                    else
                        if e.mandatory
                            break
                        end
                    end
                    
                end
                
                fns = fieldnames(match_vals);
                if ~isempty(fns)
                    for fn=1:numel(fns)
                        name = fns{fn};
                        e = match_vals.(name){1};
                        val = match_vals.(name){2};
                        bf.add_entity(name, val);
                        e.add_file(bf.fpath, val);
                    end
                    obj.files{end+1}= bf;
                    % Also add to the Layout's master list
                    obj.layout.files{end+1} = bf;
                end
            end % filenames
            
            if isempty(obj.root)
                root_node = obj;
            else
                root_node = obj.root;
            end
            
            for d=1:numel(dirnames)
                d=dirnames{d};
                
                d = fullfile(obj.fpath, d);
                %disp(['   Processing dir ', d]);
                
                % Derivative directories must always be added separately and
                % passed as their own root, so terminate if passed.
                
                %TF = startsWith(str,pattern) since R2016b
                %obj.layout.root
                %[~, path_name] fileparts(d)
                
                if startswith(d, fullfile(obj.layout.root, 'derivatives'))
                    continue
                end
                
                %
                % Skip directories that fail validation, unless force_index
                % is defined, in which case we have to keep scanning, in the
                % event that a file somewhere below the current level matches.
                % Unfortunately we probably can't do much better than this
                % without a lot of additional work, because the elements of
                % .force_index can be SRE_Patterns that match files below in
                % unpredictable ways.
                % if check_path_matches_patterns(d, self.layout.force_index):
                % 	self.force_index = True
                % else:
                %   valid_dir = layout._validate_dir(d)
                %   % Note the difference between self.force_index and
                %   % self.layout.force_index.
                %   if not valid_dir and not self.layout.force_index:
                %       continue
                %   end
                % end
                
                child_class = obj.get_child_class(d);
                % TODO: filter the config files based on include/exclude rules
                
                % % % % % %             addRequired(p, 'fpath',@(x)validateattributes(x,{'char'},{'nonempty'}));
                % % % % % %             addRequired(p, 'config', @(x)validateattributes(x,{'cell', 'Config'},{'nonempty'}));
                % % % % % %             addOptional(p, 'layout', {});
                % % % % % %             addOptional(p, 'root', {}, @(x)validateattributes(x,{'BIDSNode', 'cell'},{}));
                % % % % % %             addOptional(p, 'parent', {}, @(x)validateattributes(x,{'BIDSNode' 'cell'},{}));
                % % % % % %             addOptional(p, 'force_index', false, @(x)validateattributes(x,{'logical', 'double'},{'nonempty'}));
                
                
                %                child = child_class(d, config_list, 'root', root_node, 'parent', obj, 'force_index', obj.force_index);
                child = child_class(d, obj.config, obj.layout, root_node, obj, obj.force_index);
                
                if obj.force_index% or valid_dir:
                    obj.children{end+1} = child;
                end
            end
        end
    end
    
    methods (Access = private)
        function update_entities(obj)
            % Make all entities easily accessible in a single dict
            obj.available_entities = struct;
            
            for cfg=obj.config
                obj.available_entities = update_struct(obj.available_entities, cfg{1}.entities);
            end
        end
        
        function extract_entities(obj)
            obj.entities = struct;
            
            %             for e = 1:numel(obj.entities_)
            %                 e = obj.entities_{e};
            %
            %                 tokens = regexp(obj.fpath, obj.available_entities.(e).pattern, 'tokens');
            %                 if ~isempty(tokens)
            %                     obj.entities.(e) = tokens{1}{1};
            %                 end
            %             end
            for ent = obj.entities_
                tokens = regexp(obj.fpath, obj.available_entities.(ent{1}).pattern, 'tokens');
                if ~isempty(tokens)
                    obj.entities.(ent{1}) = tokens{1}{1};
                end
            end
        end
        
        function class_name = get_child_class(obj, fpath)
            % Return the appropriate child class given a subdirectory path.
            %
            %Args:
            %    path (str): The path to the subdirectory.
            %
            %Returns: function handle to child class
            %
            if isempty(obj.child_entity_)
                class_name = str2func('BIDSNode');
                return
            end
            
            i=1;
            
            for ce = cellify(obj.child_entity_)
                child_ent = ce{1};
                
                template = obj.available_entities.(child_ent).directory;
                if isempty(template)
                    class_name = str2func(BIDSNode);
                    return
                end
                root_path_esc = fullfile(obj.root_path, filesep);
                root_path_esc = root_path_esc(1:end-1);
                root_path_esc = strrep(root_path_esc, filesep, [filesep, filesep]);
                template = [root_path_esc,template];
                
                to_rep = regexp(template, '{(.*?)}', 'tokens');
                
                for e = 1:numel(to_rep)
                    e = to_rep{e}{1};
                    patt = obj.available_entities.(e).pattern;
                    template = strrep(template, sprintf('{%s}', e), patt);
                end
                
                tokens = regexp(fpath, template,  'tokens');
                if ~isempty(tokens)
                    child_classes = cellify(obj.child_class_);
                    class_name = str2func(child_classes{i});
                    return
                end
                i=i+1;
            end
            class_name = str2func('BIDSNode');
        end
    end
end