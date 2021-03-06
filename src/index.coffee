minify = require('html-minifier').minify
sysPath = require 'path'
mkdirp  = require 'mkdirp'
fs = require 'fs'
_ = require 'lodash'

fileWriter = (newFilePath) -> (err, content) ->
  throw err if err?
  return if not content?
  dirname = sysPath.dirname newFilePath
  mkdirp dirname, '0775', (err) ->
    throw err if err?
    fs.writeFile newFilePath, content, (err) -> throw err if err?

module.exports = class HtmlAngularJsCompiler
  brunchPlugin: yes
  type: 'template'
  extension: 'html'

  # TODO: group parameters
  constructor: (config) ->
    @public = config.paths?.public or "_public"
    @staticMask = config.plugins?.html_angular?.static_mask or /index.html/
    @compileTrigger = sysPath.normalize @public + sysPath.sep + (config.paths?.jadeCompileTrigger or 'js/dontUseMe')
    @singleFile = !!config.plugins?.html_angular?.single_file
    @singleFileName = sysPath.join @public, (config?.plugins?.html_angular?.single_file_name or "js/angular_templates.js")

  preparePairStatic: (pair) ->
    pair.path.push(pair.path.pop()[...-@extension.length] + 'html')
    pair.path.splice 0, 1, @public

  writeStatic: (pairs) ->
    _.each pairs, (pair) =>
      @preparePairStatic pair
      writer = fileWriter sysPath.join.apply(this, pair.path)
      writer null, pair.result

  parsePairsIntoAssetsTree: (pairs) ->
    assets = _.map(pairs, (v) => @removeFileNameFromPath v.path)
    root = []

    _.each assets, (path) ->
      node = root
      _.each path, (v) ->
        child = _.find node, (vv) -> vv.name is v

        if child is undefined
          child =
            name: v
            children: []

          node.push child

        node = child.children

    return root

  attachModuleNameToTemplate: (pair, assetsTree) ->
    path = @removeFileNameFromPath pair.path

    if assetsTree.length is 0
      pair.module = "#{path[0]}.templates"
      return

    findedPath = []
    node = assetsTree
    _.each path, (v) ->
      child = _.find node, (vv) -> vv.name is v
      return if child is undefined

      findedPath.push child.name
      node = child.children

    findedPath.push "templates"

    pair.module = findedPath.join '.'

  removeFileNameFromPath: (path) -> path[0..-2]

  generateModuleFileName: (module) ->
    module.filename = sysPath.join.apply(this, [@public, 'js', module.name+".js"])

  writeModules: (modules) ->

    buildModule = (module) ->
      moduleHeader = (name) ->
        """
        angular.module('#{name}', [])
        """

      templateRecord = (result, path) ->
        parseStringToJSArray = (str) ->
          stringArray = '['
          str.split('\n').map (e, i) ->
            stringArray += "\n'" + e.replace(/'/g, "\\'") + "',"
          stringArray += "''" + '].join("\\n")'

        """
        \n.run(['$templateCache', function($templateCache) {
          return $templateCache.put('#{path}', #{parseStringToJSArray(result)});
        }])
        """

      addEndOfModule = -> ";\n"

      content = moduleHeader module.name

      _.each module.templates, (template) ->
        content += templateRecord template.result, template.path

      content += addEndOfModule()

    content = ""

    _.each modules, (module) =>
      moduleContent = buildModule module

      if @singleFile
        content += "\n#{moduleContent}"
      else
        writer = fileWriter module.filename
        writer null, moduleContent

    if @singleFile
      writer = fileWriter @singleFileName
      writer null, content

  prepareResult: (compiled) ->
    pathes = _.find compiled, (v) => v.path is @compileTrigger

    return [] if pathes is undefined

    pathes.sourceFiles.map (e, i) =>
        data = fs.readFileSync e.path, 'utf8'
        content = minify data

        path: e.path.split sysPath.sep
        result: content

  onCompile: (compiled) ->
    preResult = @prepareResult compiled

    # Need to stop processing if there's nothing to process
    return if preResult.length is 0

    assets = _.filter preResult, (v) => @staticMask.test v.path
    assetsTree = @parsePairsIntoAssetsTree assets

    @writeStatic assets

    @writeModules _.chain(preResult)
      .difference(assets)
      .each((v) => @attachModuleNameToTemplate v, assetsTree)
      .each((v) -> v.path = v.path.join('/')) # concat items to virtual url
      .groupBy((v) -> v.module)
      .map((v, k) -> name: k, templates: v)
      .each((v) => @generateModuleFileName v)
      .value()
