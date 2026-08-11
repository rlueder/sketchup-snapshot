# frozen_string_literal: true

# Generates the toolbar icons.
#
# SketchUp 2016+ takes vector toolbar icons, but in a different format per
# platform: SVG on Windows, PDF on macOS. Rather than drawing them twice and
# hoping the two stay in sync, the geometry is defined once here and both files
# are emitted from it.
#
# Pure Ruby, no gems and no external converters, so this runs anywhere:
#
#   ruby tools/build_icons.rb
#
# Outputs are committed; you only need to run this after editing the shapes.
#
# Design note: these started as thin grey outlines and were invisible in
# practice — a custom toolbar on macOS is a small floating palette, the icons
# render at 24px, and SketchUp's own icons beside them are bold and coloured.
# Solid shapes with one strong colour are what actually reads at that size.

require 'fileutils'

module IconBuilder
  SIZE = 32               # icon canvas, in SVG user units and PDF points
  KAPPA = 0.5522847498    # circle-to-bezier control point ratio

  BLUE = '#2C6BD4'
  WHITE = '#FFFFFF'
  SLATE = '#4A5361'
  MIST  = '#AEB6C2'

  # --- shape primitives ---------------------------------------------------
  #
  # Coordinates are in SVG space (origin top-left, y increasing downwards).
  # The PDF writer flips y, since PDF's origin is bottom-left.
  #
  # `style` is either { fill: colour } or { stroke: colour, width: n }.

  Polyline  = Struct.new(:points, :style)
  Circle    = Struct.new(:cx, :cy, :r, :style)
  RoundRect = Struct.new(:x, :y, :w, :h, :r, :style)

  def self.fill(colour)
    { fill: colour }
  end

  ICONS = {
    # A camera, drawn solid so the silhouette carries at small sizes.
    'snapshot' => [
      RoundRect.new(11.0, 4.0, 10.0, 6.0, 1.8, fill(BLUE)),   # viewfinder bump
      RoundRect.new(2.0, 7.6, 28.0, 20.4, 4.2, fill(BLUE)),   # body
      Circle.new(16.0, 17.8, 6.8, fill(WHITE)),               # lens
      Circle.new(16.0, 17.8, 3.5, fill(BLUE))                 # aperture
    ],

    # A timeline of entries, matching how the History panel draws snapshots.
    'history' => [
      RoundRect.new(6.6, 6.0, 1.8, 20.0, 0.9, fill(MIST)),    # the rail
      RoundRect.new(14.0, 4.6, 15.5, 3.6, 1.8, fill(SLATE)),
      RoundRect.new(14.0, 14.2, 15.5, 3.6, 1.8, fill(SLATE)),
      RoundRect.new(14.0, 23.8, 10.5, 3.6, 1.8, fill(SLATE)),
      Circle.new(7.5, 6.4, 3.4, fill(BLUE)),
      Circle.new(7.5, 16.0, 3.4, fill(BLUE)),
      Circle.new(7.5, 25.6, 3.4, fill(BLUE))
    ]
  }.freeze

  module_function

  def build(dir)
    FileUtils.mkdir_p(dir)
    ICONS.each do |name, shapes|
      File.write(File.join(dir, "#{name}.svg"), svg(shapes))
      File.binwrite(File.join(dir, "#{name}.pdf"), pdf(shapes))
      puts "wrote #{name}.svg and #{name}.pdf"
    end
  end

  # --- SVG ----------------------------------------------------------------

  def svg(shapes)
    body = shapes.map { |shape| "  #{svg_shape(shape)}" }.join("\n")
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{SIZE}" height="#{SIZE}" viewBox="0 0 #{SIZE} #{SIZE}">
      #{body}
      </svg>
    SVG
  end

  def svg_shape(shape)
    paint = svg_paint(shape.style)
    case shape
    when Polyline
      points = shape.points.map { |x, y| "#{num(x)},#{num(y)}" }.join(' ')
      %(<polyline points="#{points}" #{paint}/>)
    when Circle
      %(<circle cx="#{num(shape.cx)}" cy="#{num(shape.cy)}" r="#{num(shape.r)}" #{paint}/>)
    when RoundRect
      %(<rect x="#{num(shape.x)}" y="#{num(shape.y)}" width="#{num(shape.w)}" ) +
        %(height="#{num(shape.h)}" rx="#{num(shape.r)}" #{paint}/>)
    end
  end

  def svg_paint(style)
    if style[:fill]
      %(fill="#{style[:fill]}")
    else
      %(fill="none" stroke="#{style[:stroke]}" stroke-width="#{num(style[:width])}" ) +
        %(stroke-linecap="round" stroke-linejoin="round")
    end
  end

  # --- PDF ----------------------------------------------------------------

  def pdf(shapes)
    content = pdf_content(shapes)
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{SIZE} #{SIZE}] " \
        '/Resources << >> /Contents 4 0 R >>',
      "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
    ]

    out = +"%PDF-1.4\n"
    out << "%\xE2\xE3\xCF\xD3\n".b
    offsets = []
    objects.each_with_index do |body, index|
      offsets << out.bytesize
      out << "#{index + 1} 0 obj\n#{body}\nendobj\n"
    end

    xref_offset = out.bytesize
    out << "xref\n0 #{objects.length + 1}\n"
    out << "0000000000 65535 f \n"
    offsets.each { |offset| out << format("%010d 00000 n \n", offset) }
    out << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\n"
    out << "startxref\n#{xref_offset}\n%%EOF\n"
    out.b
  end

  def pdf_content(shapes)
    ops = ['1 J', '1 j'] # round caps and joins
    shapes.each do |shape|
      ops.concat(pdf_style(shape.style))
      ops.concat(pdf_shape(shape))
    end
    ops.join("\n")
  end

  def pdf_style(style)
    if style[:fill]
      [format('%.4f %.4f %.4f rg', *hex_to_rgb(style[:fill]))]
    else
      [format('%.4f %.4f %.4f RG', *hex_to_rgb(style[:stroke])),
       format('%s w', num(style[:width]))]
    end
  end

  def pdf_shape(shape)
    painter = shape.style[:fill] ? 'f' : 'S'

    case shape
    when Polyline
      first, *rest = shape.points
      ops = [move(first)]
      rest.each { |point| ops << line(point) }
      ops << painter
    when Circle
      circle_ops(shape.cx, shape.cy, shape.r) << painter
    when RoundRect
      round_rect_ops(shape.x, shape.y, shape.w, shape.h, shape.r) << painter
    end
  end

  # Four cubic beziers, the standard circle approximation.
  def circle_ops(cx, cy, r)
    k = r * KAPPA
    [
      move([cx + r, cy]),
      curve([cx + r, cy + k], [cx + k, cy + r], [cx, cy + r]),
      curve([cx - k, cy + r], [cx - r, cy + k], [cx - r, cy]),
      curve([cx - r, cy - k], [cx - k, cy - r], [cx, cy - r]),
      curve([cx + k, cy - r], [cx + r, cy - k], [cx + r, cy]),
      'h'
    ]
  end

  def round_rect_ops(x, y, w, h, r)
    r = [r, w / 2.0, h / 2.0].min
    k = r * KAPPA
    x2 = x + w
    y2 = y + h
    [
      move([x + r, y]),
      line([x2 - r, y]),
      curve([x2 - r + k, y], [x2, y + r - k], [x2, y + r]),
      line([x2, y2 - r]),
      curve([x2, y2 - r + k], [x2 - r + k, y2], [x2 - r, y2]),
      line([x + r, y2]),
      curve([x + r - k, y2], [x, y2 - r + k], [x, y2 - r]),
      line([x, y + r]),
      curve([x, y + r - k], [x + r - k, y], [x + r, y]),
      'h'
    ]
  end

  # SVG y grows downwards, PDF y grows upwards.
  def pt(point)
    x, y = point
    [x, SIZE - y]
  end

  def move(point)
    x, y = pt(point)
    format('%s %s m', num(x), num(y))
  end

  def line(point)
    x, y = pt(point)
    format('%s %s l', num(x), num(y))
  end

  def curve(c1, c2, to)
    coords = [c1, c2, to].flat_map { |point| pt(point).map { |v| num(v) } }
    format('%s %s %s %s %s %s c', *coords)
  end

  def hex_to_rgb(hex)
    hex.delete('#').scan(/../).map { |pair| pair.to_i(16) / 255.0 }
  end

  # Trim pointless trailing zeros so the files stay readable in a diff.
  def num(value)
    format('%.4f', value.to_f).sub(/\.?0+\z/, '')
  end
end

if $PROGRAM_NAME == __FILE__
  target = ARGV[0] || File.expand_path('../src/snapshot_vcs/icons', __dir__)
  IconBuilder.build(target)
end
