{ pkgs }:
let
  inherit (pkgs.lib.strings)
    concatMapStringsSep concatStringsSep hasInfix
    stringToCharacters removePrefix removeSuffix;
  inherit (pkgs.lib.attrsets)
    genAttrs filterAttrs recursiveUpdate mapAttrs' mapAttrsToList;
  inherit (pkgs.lib.trivial) id;
  inherit (pkgs.lib.lists) flatten;
  inherit (pkgs.lib.asserts) assertMsg;
  inherit (builtins)
    mapAttrs elem isAttrs isList isString isFloat
    isBool isInt hasAttr head map typeOf foldl'
    attrValues isNull throw filter;

  # TODO handle 'any'
  inherit (genAttrs [ "string" "bool" "number" "any" ] (
    name: { __type = name; __toString = self: "${self.__type}"; }
  )) string bool number any;

  # DSL

  optional_ = type: optional type null;
  optional = type: default: {
    __type = "optional";
    __args = {
      inherit type;
      default = mkToString default;
      __toString = self:
        let default_ = toStringPrimitive self.default; in
        ''${type}${
          if default_ == ""
          then "" else ", ${default_}"
        }'';
    };
    __toString = self: ''${self.__type}(${self.__args})'';
  };

  # TODO conditionally setting an optional attribute syntax
  # https://www.terraform.io/language/expressions/type-constraints#example-conditionally-setting-an-optional-attribute

  object = args@{ ... }: {
    __type = "object";
    __attrs = (mkToString args) // {
      __toString = self: toStringBody args;
    };
    __toString = self: ''${self.__type}(${self.__attrs})'';
  };

  list = type: {
    __type = "list";
    __toString = self: ''${self.__type}(${type})'';
    __arg = type;
  };

  # block
  b = attrs@{ ... }: attrs // { __isBlock = null; };
  # argument
  a = attrs@{ ... }: attrs // { __isArgument = null; };

  # Standard library
  functions = {
    numeric = [ "abs" "ceil" "floor" "log" "max" "min" "parseint" "pow" "signum" ];
    string = [ "chomp" "endswith" "format" "formatlist" "indent" "join" "lower" "regex" "regexall" "replace" "split" "startswith" "strrev" "substr" "title" "trim" "trimprefix" "trimsuffix" "trimspace" "upper" ];
    collection = [ "alltrue" "anytrue" "chunklist" "coalesce" "coalescelist" "compact" "concat" "contains" "distinct" "element" "flatten" "index" "keys" "length" "list" "lookup" "map" "matchkeys" "merge" "one" "range" "reverse" "setintersection" "setproduct" "setsubtract" "setunion" "slice" "sort" "sum" "transpose" "values" "zipmap" ];
    encoding = [ "base64decode" "base64encode" "base64gzip" "csvdecode" "jsondecode" "jsonencode" "textdecodebase64" "textencodebase64" "urlencode" "yamldecode" "yamlencode" ];
    filesystem = [ "abspath" "dirname" "pathexpand" "basename" "file" "fileexists" "fileset" "filebase64" "templatefile" ];
    dateAndTime = [ "formatdate" "timeadd" "timecmp" "timestamp" ];
    hashAndCrypto = [ "base64sha256" "base64sha512" "bcrypt" "filebase64sha256" "filebase64sha512" "filemd5" "filesha1" "filesha256" "filesha512" "md5" "rsadecrypt" "sha1" "sha256" "sha512" "uuid" "uuidv5" ];
    ipNetwork = [ "cidrhost" "cidrnetmask" "cidrsubnet" "cidrsubnets" ];
    typeConversion = [ "can" "nonsensitive" "sensitive" "tobool" "tolist" "tomap" "tonumber" "toset" "tostring" "try" "type" ];
  };
  _lib = (mkLibFunctions functions)
    // mkAccessors {
    path.root = "";
  };


  mkLibFunction = name:
    args: assert isList args; {
      __toString = self: "${name}(${(concatMapStringsSep ", " (x: toStringPrimitive (mkToString x)) args)})";
      __isArgument = null;
      __hasToString = null;
    };
  mkLibFunctionsFromList = functionNames: assert isList functionNames; genAttrs functionNames mkLibFunction;
  mkLibFunctions = functions_@{ ... }: mkLibFunctionsFromList (flatten (attrValues functions_));
  # Operations

  # these aren't types that belong to HCL's typesystem
  filterOutNonTypes = args@{ ... }: with builtins;
    filterAttrs (name: val: !(elem (typeOf val) [ Nix.lambda Nix.null ])) args;

  # BTW, each variable should have a type
  mkVariables = attrs@{ ... }:
    (mapAttrs
      (name: value: value // {
        # TODO use toStringBody for type
        __toString = self: braces (
          concatStringsSep "\n" (filter (x: x != "") [
            (if hasAttr HCL.type self then (toStringBody_ "" false { inherit (self) type; }) else "")
            (toStringBlockBody_ "\n" false (filterAttrs (name: _: name != HCL.type) self))
          ])
        )
        ;
      })
      attrs
    ) // {
      __toString = self: concatStringsSep "\n\n" (
        mapAttrsToList (name: value: ''${KW.variable} ${qq name} ${value}'') (filterOutNonTypes self)
      );
    };

  # HCL types
  HCL = genAttrs [
    "optional"
    "list"
    "tuple"
    "set"
    "string"
    "number"
    "bool"
    "object"
    "type"
  ]
    id;

  isTypeHCL = type: arg: assert isString type; isAttrs arg && arg.__type == type;
  isOptionalHCL = isTypeHCL HCL.optional;
  isListHCL = isTypeHCL HCL.list;
  isObjectHCL = isTypeHCL HCL.object;
  isStringHCL = isTypeHCL HCL.string;
  isNumberHCL = isTypeHCL HCL.number;
  isBoolHCL = isTypeHCL HCL.bool;
  isPrimitiveHCL = arg: isAttrs arg && elem arg.__type [ HCL.string HCL.number HCL.bool ];

  checkArgType = arg: type: assert isString type;
    (isAttrs arg && type == HCL.object) ||
    (isList arg && type == HCL.list) ||
    ((isInt arg || isFloat arg) && type == HCL.number) ||
    (isString arg && type == HCL.string) ||
    (isBool arg && type == HCL.bool)
  ;

  # check that an argument is of a given type
  assertValueOfType = type: arg: assert isString type;
    assert assertMsg (checkArgType arg type) ''type mismatch: expected HCL ${type}, got Nix ${typeOf arg}'';
    true;

  # check against multiple types
  isOfAnyTypeFrom = arg: types: assert isList types;
    foldl' (m: type: m || checkArgType arg type) false types;

  # new set if attribute is present else an empty set
  # String -> Set -> Set -> Set
  ifHasAttr = attr: attrs@{ ... }: expr: assert isString attr;
    if hasAttr attr attrs then expr else { };

  # apply a function over a list of sets and then merge them
  # [a] -> (a -> Set) -> Set
  mapMerge = list: f: modifyMapMerge list id f;

  # modify the argument of a function
  # then apply the function over a list of sets
  # then merge them
  # [a] -> (a -> b) -> (b -> Set) -> Set
  modifyMapMerge = list: g: f: foldl' (x: y: recursiveUpdate x y) { } (map (x: f (g x)) list);

  # if a set's attribute values are all sets, merge these values recursively
  mergeValues = set@{ ... }: foldl' recursiveUpdate { } (attrValues set);

  # can be converted into an actual value
  hasOptionalDefault_ = arg:
    if isOptionalHCL arg then arg.__args.default != null || hasOptionalDefault arg.__args.type
    else if isObjectHCL arg then foldl' (m: val: m || hasOptionalDefault val) false (attrValues arg.__attrs)
    # TODO add more checks
    else false;

  # can be used for mapping a variable to a value
  # list(object({a = optional(string, "a")}))
  # if someone accesses this list, one should get a list of objects [{a = "a"}]
  # What should be its length?
  # we'll leave only things that can be turned to values, not lists
  hasOptionalDefault = arg:
    hasOptionalDefault_ arg ||
    (isListHCL arg && hasOptionalDefault arg.__arg);

  # convert a variable to a value
  # if a variable contains an object with some optional default values
  # or optionals themselves
  toValue = variable@{ ... }:
    let type_ = variable.__type; in
    if type_ == HCL.object then
      let
        withDefaultValues_ = filterAttrs (_: val: hasOptionalDefault_ val) variable.__attrs;
        defaultValues = mapAttrs (_: val: toValue val) withDefaultValues_;
      in
      defaultValues
    # we should not discard the default since we don't yet have a value
    # we should combine type and the default
    else if type_ == HCL.optional then mapToValue_ variable.__args.type variable.__args.default
    else throw ''unexpected HCL ${type_}'';


  # TODO how to represent a list of objects with optional values?
  # we don't
  # TODO how to update lists with such values

  # TODO can there be no type?
  # this is a top set of variables, so, we should to filter out the __toString

  mapToValue = variable@{ ... }: value: mapToValue_ variable.type value;

  # use variable as a template to supplement the value
  mapToValue_ = variable@{ ... }: value:
    let type_ = variable.__type; in
    if type_ == HCL.object && assertValueOfType type_ value then
      let
        withDefaultValues = filterAttrs (_: val: hasOptionalDefault val) (variable.__attrs);
        withDefaultValues_ = filterAttrs (_: val: hasOptionalDefault_ val) withDefaultValues;
        defaultValues = mapAttrs (_: val: toValue val) withDefaultValues_;
        mappedValues =
          mapAttrs
            (name: val:
              let attr = if hasAttr name withDefaultValues then withDefaultValues."${name}" else null; in
              if isNull attr then val else mapToValue_ attr val
            )
            (filterOutNonTypes value);
      in
      # we want to add the missing attributes to a value
      defaultValues // mappedValues

    else if type_ == HCL.list && assertValueOfType type_ value then
      map (val: mapToValue_ variable.__arg val) value
    # we can discard the default since we already have a value
    # no need to check value type since it can't directly represent an optional
    else if type_ == HCL.optional then mapToValue_ variable.__args.type value
    else if isOfAnyTypeFrom value [ HCL.string HCL.number HCL.bool ] then value
    else builtins.throw "not yet implemented for ${type_}";


  # TODO make accessors for variables, not values
  # sometimes, values may be missing

  mkDefaultTypeValue = type_@{ ... }:
    if isObjectHCL type_ then { }
    else if isOptionalHCL type_
    then
      (
        if type_.__args.default != null then type_.__args.default
        else mkDefaultTypeValue type_.__args.type
      )
    else if isListHCL type_ then [ ]
    else if isStringHCL type_ then ""
    else if isNumberHCL type_ then 1
    else if isBoolHCL type_ then false
    # for number, bool, string
    # TODO hope it will be filtered out
    else throw "got type ${type_.__type}. Unbelievable!";

  mkDefaultVariableValue = variable@{ ... }:
    if hasAttr KW.default variable then variable.default
    else mkDefaultTypeValue variable.type;

  # Take a Set of variables and a Set of values
  # use variables as templates to supplement these values
  # attrs -> variables is injective
  mkVariableValues = variables@{ ... }: attrs@{ ... }:
    let
      # need to set the default values for missing values
      # so that we have accessors for all variables
      attrs_ = (mapAttrs (name: val: mkDefaultVariableValue val) variables) // attrs;
      # attrs_ = (mapAttrs (name: val: null) variables) // attrs;
      val_ = (mapAttrs
        (name: val: mkToString
          # FIXME
          (mapToValue variables."${name}" val)
          # val
        )
        attrs_) // {
        __toString = self: toStringBody_ "\n\n" false (
          filterAttrs (name: val: name != KW.__) self
        );
      };
    in
    val_ // { __ = mkAccessors { var = val_; }; };

  # Representation
  qq = x: ''"${x}"'';
  bb = x: "$" + "{${x}}";

  eot = arg: assert isString arg;
    ''
      <<-EOT
      ${arg}
      EOT'';

  brackets = x: "[${if x == "" then "" else "\n${x}\n"}]";
  braces = x: "{${if x == "" then "" else "\n${x}\n"}}";

  Nix = genAttrs [ "true" "false" "int" "float" "set" "lambda" "null" ] id;

  # toString any primitive value
  toStringPrimitive = arg:
    with builtins;
    if isBool arg then (if arg then Nix.true else Nix.false)
    else if isString arg then
      (if elem "\n" (stringToCharacters arg) then eot else qq) arg
    # TODO what if a list of objects?
    else if isList arg then {
      __toString = self: brackets (
        concatMapStringsSep ",\n" toStringPrimitive arg
      );
    }
    # else if isAttrs arg then "${mkToStringBody arg}"
    # else if isAttrs arg then toStringBody arg
    else if elem (typeOf arg) [ Nix.int Nix.float Nix.set ] then "${toString arg}"
    # "path", "lambda", "null"
    else if isNull arg then ""
    else throw "bad type: ${typeOf arg}";

  # string representation of a body of an argument
  # we assume that it doesn't contain any blocks
  toStringBody = toStringBody_ "\n" true;

  # String -> Bool -> Set -> String
  toStringBody_ = nl: needBraces: attrs@{ ... }:
    assert isString nl && isBool needBraces;
    # use the string representation that this value has
    if hasAttr KW.__hasToString attrs then attrs.__toString { }
    else
      (if needBraces then braces else id) (
        concatMapStringsSep nl (x: "${x}") (
          attrValues (
            mapAttrs (name: val: "${name} = ${toStringPrimitive val}") (
              filterOutNonTypes attrs
            )
          )
        )
      );

  # make argument values toString-able
  mkToString = arg:
    if isAttrs arg then mkToStringBody arg
    else if isList arg then mkToStringList arg
    else arg;

  # make objects and their values toString-able
  # we want to be able to print nested objects
  mkToStringBody = attrs@{ ... }:
    if hasAttr KW.__hasToString attrs then attrs
    else
      (mapAttrs (_: value: mkToString value) attrs) // {
        __toString = toStringBody;
      };

  # make lists toString-able
  mkToStringList = attrs: assert isList attrs; map (val: mkToString val) attrs;

  # add special attributes to object values so that
  # we can get a chain "a.b.c" when toString a.b.c
  mkAccessors = attrs@{ ... }: mkAccessors_ attrs "";
  mkAccessors_ = attrs@{ ... }: path:
    (mapAttrs
      (name: val:
        let path_ = "${path}${if path == "" then "" else "."}${name}"; in
        (
          if isAttrs val
          then mkAccessors_ val
          # if it's not a set, the next attribute cannot be accessed via .
          # hence, no __functor
          else x: {
            __toString = self: "${x}";
            __isArgument = null;
            __hasToString = null;
          }
        ) path_
      )
      (filterOutNonTypes attrs)
    ) // (
      let
        __functor = self: path_: assert isString path_; mkAccessors_ { } "${path}.${path_}";
        __toString = self: path;
        __isArgument = null;
        # a special attribute that allows for custom toString representations
        __hasToString = null;
      in
      { inherit __functor __toString __hasToString __isArgument; }
    );

  toStringBlockBody = toStringBlockBody_ "\n" true;

  # toString a block body
  # assume arguments are values and contain no blocks
  toStringBlockBody_ = nl: needBraces: attrs@{ ... }:
    assert isBool needBraces;
    (if needBraces then braces else id) (
      concatStringsSep nl (
        # we want a list of representations of body attributes and blocks
        flatten (
          mapAttrsToList
            (name: val:
              if isAttrs val then
                (
                  # a new block starts so the new block type won't be a label
                  if hasAttr KW.__isArgument val then
                    [ ("${name} = ${toStringBody (mkToStringBody val)}") ]
                  # if a new block starts, there go not labels, but block types
                  else
                    let isLabel = !hasAttr KW.__isBlock val; in
                    map
                      (x: "${name} ${x}")
                      (toStringBlock val isLabel)
                )
              else [ ''${name} = ${toStringPrimitive val}'' ]
            )
            (filterOutNonTypes attrs)
        )
      )
    )
  ;


  # return a list of representations 
  # of blocks (a "b" "c" { ... })
  # and arguments (a = { ... })
  toStringBlock = attrs@{ ... }: isLabel:
    assert isBool isLabel;
    if hasAttr KW.__isArgument attrs then [ (toStringBody (mkToStringBody attrs)) ]
    else if hasAttr KW.__isBlock attrs then [ (toStringBlockBody attrs) ]
    # it's a part of a header of a block
    else
      flatten
        (
          mapAttrsToList
            (name: val:
              if isAttrs val then
                let
                  name_ = (if isLabel then qq else id) name;
                  infix = if hasAttr KW.__isArgument val then " = " else " ";
                  reprs = toStringBlock val true;
                in
                map (val_: "${name_}${infix}${val_}") reprs
              else [ "${name} = ${val}" ]
            )
            (filterOutNonTypes attrs)
        )
  ;

  # keywords
  KW = genAttrs [
    "__"
    "local"
    "locals"
    "resource"
    "var"
    "__isArgument"
    "__isBlock"
    "__toString"
    "__hasToString"
    "variable"
    "default"
  ]
    id;

  # construct blocks and arguments from a set
  mkBlocks = mkBlocks_ { };
  mkBlocks_ = __@{ ... }: attrs@{ ... }:
    let
      as =
        mapAttrs
          (name: val@{ ... }:
            val // {
              __toString = self:
                let infix = if hasAttr KW.__isArgument val then " = " else " "; in
                concatStringsSep "\n\n" (
                  map (str: "${name}${infix}${str}")
                    (toStringBlock val true)
                );
            })
          attrs;
    in
    as // (
      let
        std =
          {
            __toString = self:
              concatStringsSep "\n\n" (
                attrValues (filterAttrs (name: _: name != KW.__) (filterOutNonTypes self))
              );

            __ = recursiveUpdate __
              (
                {
                  local = ifHasAttr KW.locals as (mkAccessors_ (as.locals) KW.local);
                }
                // (ifHasAttr KW.resource as (mkAccessors (filterOutNonTypes as.resource)))
              );
            # Set -> (Set -> Set) -> Set
            __functor = self: x:
              (
                y: y // { __toString = self_: "${self}\n\n${y}"; }
              ) (mkBlocks_ self.__ (x self.__));
          };
      in
      std
    );
in
{
  inherit
    optional_ optional object list b a _lib mapMerge modifyMapMerge
    mkVariables mkVariableValues mkBlocks mkBlocks_ bb qq;
  # just names
  inherit string number bool any;
  # functions for custom library
  inherit mkAccessors;
}
