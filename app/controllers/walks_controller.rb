class WalksController < ApplicationController
  include Kaminari::ActionViewExtension
  XMPS_SRID = 4301
  EARTH_RADIUS = 6370986
  DEFAULT_SRID = 4326
  DEG_TO_RAD = Math::PI/180

  def index
    year_range = ActiveRecord::Base.connection.select_one("select extract(year from min(date)) as min, extract(year from max(date)) as max from walks")
    @year_opts = [''] + (year_range['min'].to_i .. year_range['max'].to_i).to_a.reverse
    @month_opts = [''] + (1 .. 12).to_a
  end

  def atom
    @walks = Walk.order('id desc').limit(15)
    @atom_title = 'walkrr chez sugi'
    @atom_id = 'tag:chez-sugi.net,1997:walkrr'
    headers["Content-Type"] = "application/atom+xml";
    render :template => 'walks/atom.xml.erb'

  end

  def add_area
    @factory = get_factory
    latitude = params[:latitude].to_f
    longitude = params[:longitude].to_f
    point = @factory.point(longitude, latitude)
    area = Area.find(:first, :conditions => ["st_contains(the_geom, :point)", {:point => point}])

    respond_to do |format|
      format.json {render :json => {:jcode => area.jcode, :the_geom => area.the_geom.as_encoded_paths}}
    end

  end

  def search
    @factory = get_factory
    id = params[:id]
    date = params[:date]
    radius = params[:radius]
    latitude = params[:latitude]
    longitude = params[:longitude]
    year = params[:year]
    month = params[:month]
    page = params[:page] || 0
    per_page = params[:per_page] || 20
    order_hash = {
      "new_first" => "date desc",
      "old_first" => "date",
      "long_first" => "length desc",
      "short_first" => "length",
      "east_first" => "xmax(PATH) desc",
      "west_first" => "xmin(PATH)",
      "south_first" => "ymin(PATH)",
      "north_first" => "ymax(PATH) desc"
    }
    conditions = nil
    order = order_hash[params[:order]] || "date desc"
    sqls = []
    values = {}
    unless year.blank?
      sqls << 'extract(year from date) = :year'
      values[:year] = year
    end
    unless month.blank?
      sqls << 'extract(month from date) = :month'
      values[:month] = month
    end
    if id 
      conditions = {:id => id}
    elsif date
      conditions = {:date => date}
    else
      case params[:type]
      when "neighbor"
        point = @factory.point(longitude.to_f, latitude.to_f)
        #      sqls << "st_dwithin(transform(path, :srid), transform(:point, :srid), :distance)"
        dlat = radius.to_f / DEG_TO_RAD / EARTH_RADIUS
        dlon = dlat / Math.cos(latitude.to_f * DEG_TO_RAD)
        pll = @factory.point(longitude.to_f-dlon, latitude.to_f-dlat)
        pur = @factory.point(longitude.to_f+dlon, latitude.to_f+dlat)
        sqls << "st_makebox2d(:pll, :pur) && path and st_distance_sphere(path, :point) <= :radius"
        values.merge!({:radius => radius.to_f, :point => point,
                        :pll => pll, :pur => pur
                      })
      when "areas"
        sqls << "id in (select distinct id from walks inner join areas on jcode in (:areas) where path && the_geom and intersects(path, the_geom))"
        values.merge!({:areas =>params[:areas].split(/,/)})
      when "cross"
        path = GeometryEncodeUtil.line_string_from_encoded_path(@factory, params[:searchPath])
        sqls << "path && :path and intersects(path, :path)"
        values.merge!({:path => path})
      end
      conditions = [sqls.join(' and '), values]
    end
    @walks = Walk.where(conditions)
      .select(%w(id date start "end" length path))
      .page(page).per(per_page)
      .order(order)

    walk_hashs = nil
    if @walks.total_count == 1
      walks_hash = @walks.map{|w| w.to_hash_with_path}
    else
      walks_hash = @walks.map{|w| w.to_hash}
    end
    result = {
      :items => walks_hash, 
      :total_count => @walks.total_count,
      :current_page => @walks.current_page
    } 
    result[:params] = params.keys.select{|key| key != :page }.map{|key| "#{key.to_s}=#{params[key]}"}.push("page=#{@walks.current_page+1}").join('&') unless @walks.last_page?
    respond_to do |format|
      format.json {render :json => result.to_json}
    end
  end

  # GETs should be safe (see http://www.w3.org/2001/tag/doc/whenToUseGet.html)
#  verify :method => :post, :only => [ :destroy, :create, :update ],
 #        :redirect_to => { :action => :list }


  def show
    ids = params[:id]
    @select = params[:select]
    unless ids.is_a? Array
      ids = [ids]
    end
    @walks = Walk.find(ids)
    items = @walks.map do |item|
      item.to_hash_with_path
    end
    respond_to do |format| 
      format.json {render :json => items.to_json}
    end
  end

  def save
    @factory = get_factory
    path = GeometryEncodeUtil.line_string_from_encoded_path(@factory, params[:path])
    if params[:id].blank?
      #temporary hack for https://github.com/fragility/spatial_adapter/issues/26
      @walk = Walk.create(:date => params[:date], :start => params[:start], :end => params[:end])
      @walk.path = path
#      @walk = Walk.new(:date => params[:date], :start => params[:start], :end => params[:end], :path => path)
    else
      @walk = Walk.find(params[:id])      
      @walk.date = params[:date]
      @walk.start = params[:start]
      @walk.end = params[:end]
      @walk.path = path
    end
    @walk.save
    respond_to do |format| 
      format.json {render :json => @walk.to_json}
    end
  
  end

  def destroy
    @walk =  Walk.destroy(params[:id])
  end

  def export
    format = params[:format]
    format = "kml" unless format
    ids = params[:id]
    filename = 'walks'
    unless ids.is_a? Array
      ids = [ids]
    end
    filename = ids[0] if ids.length == 1
    @walks = Walk.find(ids)
    case format
    when "kml"
      headers["Content-Type"] = "application/vnd.google-earth.kml+xml"
      headers["Content-Disposition"] = "attachment; filename=#{filename}.kml"
      render :template => 'walks/export_kml.xml.erb'
    end
  end

  def import
    headers["Content-Type"] = "text/plain";
    file = params[:file]
    content = file.read
    @paths = case file.original_filename[/\.[^.]+$/]
    when ".kml"
      import_kml(content)         
    when ".xmps"
      import_xmps(content)       
    end
    render :template => 'walks/import.js.erb'
  end

  private
  
  def import_kml(content)
    puts 'contents:' + content
    doc = REXML::Document.new content
    doc.elements.collect("//LineString") do |elm|
      line_string = LineString.from_kml(elm.to_s)
      line_string.as_encoded_path
    end
  end   

  def coord_to_f(point, unit)
    case unit
    when "dmms"
      dm, m, ms = point.split("/"); 
      dm.to_f + m.to_f/60 + ms.to_f/3600000
    when "dms"
      dm, m, s = point.split("/"); 
      dm.to_f + m.to_f/60 + s.to_f/3600
    when "deg"
      point.to_f
    when "msec"
      point.to_f/3600000
    end
  end

  def transform_path(path, srid)
    Walk.find_by_sql(["select transform(?, ?) as path", path, srid])[0].path
  end

  def import_xmps(content)
    doc = REXML::Document.new content
    doc.elements("//polyline/locator/points").collect do |elm|
      coords = elm.text
      unit = elm.attributes["unit"]
      coords = coords.split(",").map{|item| coord_to_f(item, unit)}
      points = []
      while coords.length > 0 do
        lat = coords.shift
        lng = coords.shift
        points.push([lng, lat])
      end
      transform_path(LineString.from_coordinates(points, XMPS_SRID), DEFAULT_SRID).text_representation
    end
    
  end

  def get_factory
    RGeo::Cartesian.simple_factory( :srid => DEFAULT_SRID)    
  end
  
end
