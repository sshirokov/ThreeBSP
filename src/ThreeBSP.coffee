EPSILON = 1e-5
COPLANAR = 0
FRONT = 1
BACK = 2
SPANNING = 3

# Call the callback with no arguments
# then return the first value.
# Used to construct chainable
# callbacks
returning = (value, fn) ->
  fn()
  value

class Timelimit
  constructor: (@timeout, @progress) -> "NOTHING"

  check: =>
    return unless @started?
    returning (elapsed = (Date.now() - @started)), =>
      if elapsed >= @timeout ? Infinity
        throw new Error("Timeout reached: #{elapsed}/#{@timeout}, #{@tasks ? 0} tasks unfinished #{@done ? 0} finished.")

  start: =>
    @started ?= Date.now()
    @tasks ?= 0
    @total ?= 0
    @total += 1
    @tasks += 1
    do @check

  finish: =>
    throw new Error("Finished more tasks than started") if @tasks? and @tasks < 1
    @tasks -= 1
    elapsed = @check()
    @done ?= 0
    @done += 1
    @progress(@done, @total) if @progress?
    if @tasks == 0
      "Finished #{@done} tasks in #{elapsed}/#{@timeout} ms"
      @started = @done = @total = undefined

  doTask: (block) =>
    do @start
    result = block()
    do @finish
    result


##
## ThreBSP Driver
#
# Can be instantiated with THREE.Geometry,
# THREE.Mesh or a ThreeBSP.Node
class window.ThreeBSP
  constructor: (treeIsh, @matrix, @options={}) ->
    if @matrix? and not (@matrix instanceof THREE.Matrix4)
      @options = @matrix
      @matrix = undefined

    @options ?= {}
    @matrix ?= new THREE.Matrix4()

    # Start a timer if one wasn't passed
    @options.timer ?= new Timelimit(
      @options.timer?.timeout ? @options.timeout
      @options.timer?.progress ? @options.progress
    )

    @tree   = @toTree treeIsh

  # Evaluate block after replacing @timer with new_timer
  # then put @timer back after block returns
  withTimer: (new_timer, block) =>
    old_timer = @options.timer
    try
      @options.timer = new_timer
      do block
    finally
      @options.timer = old_timer

  toTree: (treeIsh) =>
    return treeIsh if treeIsh instanceof ThreeBSP.Node
    polygons = []
    geometry =
      if treeIsh instanceof THREE.Geometry
        treeIsh
      else if treeIsh instanceof THREE.Mesh
        treeIsh.updateMatrix()
        @matrix = treeIsh.matrix.clone()
        treeIsh.geometry

    for face, i in geometry.faces
      do (face, i) =>
        faceVertexUvs = geometry.faceVertexUvs?[0][i]
        faceVertexUvs ?= [new THREE.Vector2(), new THREE.Vector2(),
                          new THREE.Vector2(), new THREE.Vector2()]
        polygon = new ThreeBSP.Polygon()
        for vName, vIndex in ['a', 'b', 'c', 'd']
          if (idx = face[vName])?
            vertex = geometry.vertices[idx]
            vertex = new ThreeBSP.Vertex vertex.x, vertex.y, vertex.z,
              face.vertexNormals[0],
              new THREE.Vector2(faceVertexUvs[vIndex].x, faceVertexUvs[vIndex].y)
            vertex.applyMatrix4 @matrix
            polygon.vertices.push vertex
        polygons.push polygon.calculateProperties()
    new ThreeBSP.Node polygons, @options

  # Converters/Exporters
  toMesh: (material=new THREE.MeshNormalMaterial()) => @options.timer.doTask =>
    geometry = @toGeometry()
    returning (mesh = new THREE.Mesh geometry, material), =>
      mesh.position.getPositionFromMatrix @matrix
      mesh.rotation.setEulerFromRotationMatrix @matrix

  toGeometry: () => @options.timer.doTask =>
    matrix = new THREE.Matrix4().getInverse @matrix

    returning (geometry = new THREE.Geometry()), =>
      for polygon in @tree.allPolygons()
        @options.timer.doTask =>
          polyVerts = (v.clone().applyMatrix4(matrix) for v in polygon.vertices)
          for idx in [2...polyVerts.length]
            verts = [polyVerts[0], polyVerts[idx-1], polyVerts[idx]]
            vertUvs = (new THREE.Vector2(v.uv?.x, v.uv?.y) for v in verts)

            face = new THREE.Face3 (geometry.vertices.push(v) - 1 for v in verts)..., polygon.normal.clone()
            geometry.faces.push face
            geometry.faceVertexUvs[0].push vertUvs

  # CSG Operations
  subtract: (other) => @options.timer.doTask => other.withTimer @options.timer, =>
    [us, them] = [@tree.clone(), other.tree.clone()]
    us
      .invert()
      .clipTo(them)
    them
      .clipTo(us)
      .invert()
      .clipTo(us)
      .invert()
    new ThreeBSP us.build(them.allPolygons()).invert(), @matrix, @options

  union: (other) => @options.timer.doTask => other.withTimer @options.timer, =>
    [us, them] = [@tree.clone(), other.tree.clone()]
    us.clipTo them
    them
      .clipTo(us)
      .invert()
      .clipTo(us)
      .invert()
    new ThreeBSP us.build(them.allPolygons()), @matrix, @options

  intersect: (other) => @options.timer.doTask => other.withTimer @options.timer, =>
    [us, them] = [@tree.clone(), other.tree.clone()]
    them
      .clipTo(us.invert())
      .invert()
      .clipTo(us.clipTo(them))
    new ThreeBSP us.build(them.allPolygons()).invert(), @matrix, @options


##
## ThreeBSP.Vertex
class ThreeBSP.Vertex extends THREE.Vector3
  constructor: (x, y, z, @normal=new THREE.Vector3(), @uv=new THREE.Vector2()) ->
    super x, y, z

  clone: ->
    new ThreeBSP.Vertex @x, @y, @z, @normal.clone(), @uv.clone()

  lerp: (v, alpha) => returning super, =>
    # @uv is a V2 instead of V3, so we perform the lerp by hand
    @uv.add v.uv.clone().sub(@uv).multiplyScalar alpha
    @normal.lerp v, alpha

  interpolate: (args...) =>
    @clone().lerp args...

##
## ThreeBSP.Polygon
class ThreeBSP.Polygon
  constructor: (@vertices=[], @normal, @w) ->
    @calculateProperties() if @vertices.length

  calculateProperties: () => returning this, =>
    [a, b, c] = @vertices
    @normal = b.clone().sub(a).cross(
      c.clone().sub a
    ).normalize()
    @w = @normal.clone().dot a

  clone: () =>
    new ThreeBSP.Polygon(
      (v.clone() for v in @vertices),
      @normal.clone(),
      @w
    )

  invert: () => returning this, =>
    @normal.multiplyScalar -1
    @w *= -1
    @vertices.reverse()

  classifyVertex: (vertex) =>
    side = @normal.dot(vertex) - @w
    switch
      when side < -EPSILON then BACK
      when side > EPSILON then FRONT
      else COPLANAR

  classifySide: (polygon) =>
    [front, back] = [0, 0]
    tally = (v) => switch @classifyVertex v
      when FRONT then front += 1
      when BACK  then back += 1
    (tally v for v in polygon.vertices)
    return FRONT    if front > 0  and back == 0
    return BACK     if front == 0 and back > 0
    return COPLANAR if front == back == 0
    return SPANNING

  # Return a list of polygons from `poly` such
  # that no polygons span the plane defined by
  # `this`. Should be a list of one or two Polygons
  tessellate: (poly) =>
    {f, b, count} = {f: [], b: [], count: poly.vertices.length}

    return [poly] unless @classifySide(poly) == SPANNING
    # vi and vj are the current and next Vertex
    # i  and j  are the indexes of vi and vj
    # ti and tj are the classifications of vi and vj
    for vi, i in poly.vertices
      vj = poly.vertices[(j = (i + 1) % count)]
      [ti, tj] = (@classifyVertex v for v in [vi, vj])
      f.push vi if ti != BACK
      b.push vi if ti != FRONT
      if (ti | tj) == SPANNING
        t = (@w - @normal.dot vi) / @normal.dot vj.clone().sub(vi)
        v = vi.interpolate vj, t
        f.push v
        b.push v

    returning (polys = []), =>
      polys.push new ThreeBSP.Polygon(f) if f.length >= 3
      polys.push new ThreeBSP.Polygon(b) if b.length >= 3


  subdivide: (polygon, coplanar_front, coplanar_back, front, back) =>
    for poly in @tessellate polygon
      side = @classifySide poly
      switch side
        when FRONT then front.push poly
        when BACK  then back.push poly
        when COPLANAR
          if @normal.dot(poly.normal) > 0
            coplanar_front.push poly
          else
            coplanar_back.push poly
        else
          throw new Error("BUG: Polygon of classification #{side} in subdivision")

##
## ThreeBSP.Node
class ThreeBSP.Node
  clone: => returning (node = new ThreeBSP.Node(@options)), =>
    node.divider  = @divider?.clone()
    node.polygons = @options.timer.doTask => (p.clone() for p in @polygons)
    node.front    = @options.timer.doTask => @front?.clone()
    node.back     = @options.timer.doTask => @back?.clone()

  constructor: (polygons, @options={}) ->
    if polygons? and not (polygons instanceof Array)
      @options = polygons
      polygons = undefined

    @polygons = []
    @options.timer.doTask =>
      @build(polygons) if polygons? and polygons.length

  build: (polygons) => returning this, =>
    sides = front: [], back: []
    @divider ?= polygons[0].clone()

    @options.timer.doTask =>
      for poly in polygons
        @options.timer.doTask =>
          @divider.subdivide poly, @polygons, @polygons, sides.front, sides.back

    for own side, polys of sides
      if polys.length
        @[side] ?= new ThreeBSP.Node(@options)
        @[side].build polys

  isConvex: (polys) =>
    for inner in polys
      for outer in polys
        return false if inner != outer and outer.classifySide(inner) != BACK
    true

  allPolygons: => @options.timer.doTask =>
    @polygons.slice()
      .concat(@front?.allPolygons() or [])
      .concat(@back?.allPolygons() or [])

  invert: => returning this, => @options.timer.doTask =>
    for poly in @polygons
      @options.timer.doTask => do poly.invert
    for flipper in [@divider, @front, @back]
      @options.timer.doTask => flipper?.invert()
    [@front, @back] = [@back, @front]

  clipPolygons: (polygons) => @options.timer.doTask =>
    return polygons.slice() unless @divider
    front = []
    back = []

    for poly in polygons
      @options.timer.doTask =>
        @divider.subdivide poly, front, back, front, back

    front = @front.clipPolygons front if @front
    back  = @back.clipPolygons  back  if @back

    if @back
      return front.concat back
    else
      return front

  clipTo: (node) => returning this, => @options.timer.doTask =>
    @polygons = node.clipPolygons @polygons
    @front?.clipTo node
    @back?.clipTo node
