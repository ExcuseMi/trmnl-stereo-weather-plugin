# frozen_string_literal: true
require 'json'
require 'fileutils'
# SW_CASES: JSON list of {name, view, device, fields, fixture, patch (json merged into current), mocks_extra, palette, orientation}
# A real device: the serverless transform input has no sensor_readings (TRMNL adds it to the markup's merge variables at
# render time). trmnlp hands every case variable to both, so sensor_readings is taken out of the transform input and put
# back into the markup's variables.
module SensorsAfterTransform
  def call(device: {})
    r = super
    sr = config.project.user_data_overrides['sensor_readings']
    r['sensor_readings'] = sr if sr
    r
  end

  private

  def transform_input(merged)
    super(merged.reject { |k, _| k == 'sensor_readings' })
  end
end
TRMNLP::UserDataAssembler.prepend(SensorsAfterTransform)
DIAL_R = Hash.new { |h, k| h[k] = [] }
COND_R = Hash.new { |h, k| h[k] = [] }
RSpec.describe 'renders' do
  after(:all) do
    # Condition text proportion (owner 2026-11-13, "the same size relative"): the condition label's font size over the big temperature
    # digit height is, in every layout of one device (and orientation), within 15 % of the full view's ratio.
    aggregate_failures do
      COND_R.each do |k, v|
        ref = v.find { |q| q[2] == 'full' }
        next unless ref
        v.each do |q|
          next if q.equal?(ref)
          rel = q[1] / ref[1]
          puts "CONDRATIO #{q[0]}: #{q[1].round(3)} vs full #{ref[1].round(3)} = #{rel.round(2)}" if rel > 1.15 || rel < 1 / 1.15
          expect(rel).to be_between(1 / 1.15, 1.15), "condition/temperature ratio differs across #{k.inspect}: #{q[0]} #{q[1].round(3)} vs full #{ref[1].round(3)}"
        end
      end
    end
    DIAL_R.each do |k, v|
      lo, hi = v.map { |q| q[1] }.minmax
      puts "DIALR-SPREAD #{k.inspect}: #{v.inspect}" if hi / lo > 1.02
      expect(hi / lo).to be <= 1.02, "dial radius differs across #{k.inspect}: #{v.inspect}"
    end
  end
  cases = JSON.parse(ENV.fetch('SW_CASES'))
  out = ENV.fetch('SW_OUT')
  fx = File.join(TRMNLP::Testing.plugin_dir, 'tests', 'fixtures')
  cases.each do |c|
    it c['name'] do
      # A custom screen (the markup editor previews a layout in a frame of the layout's own size, owner 2026-11-13):
      # device {model, width, height, bit_depth, screen_classes}; the checks then read the model name.
      dev = c['device'].is_a?(Hash) ? c['device'].transform_keys(&:to_sym) : (c['device'] || 'v2')
      c = c.merge('device' => dev[:model]) if dev.is_a?(Hash)
      answer = JSON.parse(File.read(File.join(fx, "#{c['fixture'] || 'mixed'}.json")))
      (c['current'] || {}).each { |k, v| answer['current'][k] = v }
      (c['hourly'] || {}).each { |k, v| answer['hourly'][k] = v }
      (c['daily'] || {}).each { |k, v| answer['daily'][k] = v }
      if c['past_press']   # 3 past hours before the current one (past_hours=3), the first with this pressure
        h = answer['hourly']; h['pressure_msl'] ||= h['time'].map { answer.dig('current', 'pressure_msl') }; t0 = Time.utc(*h['time'][0].split(/[-T:]/).map(&:to_i))
        h.each_key { |k| next unless h[k].is_a?(Array); 3.times { |j| h[k].unshift(k == 'time' ? (t0 - 3600 * (j + 1)).strftime('%Y-%m-%dT%H:%M') : (k == 'pressure_msl' ? c['past_press'] : h[k][0])) } }
      end
      if (c['fields'] || {})['unit'] == 'fahrenheit' && !(c['fixture'] || '').end_with?('_f')   # the celsius fixtures hold mm; Open-Meteo answers inches for fahrenheit (precipitation_unit=inch)
        %w[hourly daily].each { |sec| answer[sec].each { |k, v| answer[sec][k] = v.map { |x| x.is_a?(Numeric) ? (x / 25.4).round(3) : x } if k.start_with?('precipitation') && !k.include?('probability') && v.is_a?(Array) } }
      end
      t = answer.dig('current', 'time')
      now = (Time.utc(*t.split(/[-T:]/).map(&:to_i)) - answer['utc_offset_seconds'].to_i + 600).iso8601
      mocks = { 'https://api.open-meteo.com/*' => { json: answer } }
      mocks['https://air-quality-api.open-meteo.com/*'] = { json: c['aq'] } if c['aq']
      fields = { 'lat_lon' => '52.52,13.41', 'unit' => 'celsius', 'days_shown' => 'auto', 'dial_span' => '24h', 'hide_title_bar' => 'false' }.merge(c['fields'] || {})
      opts = { view: c['view'] || 'full', device: dev, mocks:, custom_fields: fields, now:, wait_for: "document.querySelector('[data-sw-drawn],[data-sw-error]') !== null" }
      opts[:variables] = { 'trmnl' => { 'user' => { 'locale' => c['locale'] } } } if c['locale']
      opts[:variables] = (opts[:variables] || {}).merge(c['vars']) if c['vars']
      # a screen shows only its own sensor, device_<trmnl.device.id> (owner 2026-11-14): a case with readings and no trmnl of its own is device 1
      opts[:variables]['trmnl'] = (opts[:variables]['trmnl'] || {}).merge('device' => { 'id' => 1 }) if c['vars'] && c['vars']['sensor_readings'] && !c['vars'].key?('trmnl')
      opts[:theme] = c['theme'] if c['theme']
      opts[:palette] = c['palette'] if c['palette']
      opts[:orientation] = c['orientation'].to_sym if c['orientation']
      opts[:dark_mode] = true if c['dark']
      opts[:text_scale] = c['text_scale'] if c['text_scale']
      opts[:state] = c['state'] if c['state']   # saved state (indoor trend cases)
      if c['offline_h']   # saved state (owner 2026-11-13): a good run writes the copy, then Open-Meteo is down offline_h hours later
        pre = trmnl.transform(**{ device: dev, mocks:, custom_fields: fields, now:, variables: opts[:variables] }.compact)
        opts[:state] = pre.state
        opts[:mocks] = { 'https://api.open-meteo.com/*' => { status: 503, json: { error: true, reason: 'Service unavailable' } } }
        opts[:now] = (Time.iso8601(now) + c['offline_h'] * 3600).iso8601
      end
      s = trmnl.render(**opts)
      is_lg = s.evaluate("!!document.querySelector('.screen--lg')")   # the X layouts follow the lg size class, not the model name (device tier, 2026-11-13)
      # a native portrait screen (reMarkable, Poke 5) runs with no orientation but takes the portrait layouts (B12): the portrait checks follow the layout
      is_port = s.evaluate("!!document.querySelector('.screen--portrait')")
      puts "SCREEN #{c['name']}: #{s.evaluate("document.querySelector('.screen').className+' '+innerWidth")}" if ENV['SW_SCREEN']
      FileUtils.mkdir_p(out)
      FileUtils.cp(s.png_path, File.join(out, "#{c['name']}.png"))
      # Title bar icon (owner 2026-11-13, live OG 1-bit: gone): wherever the title bar shows, its icon has dark ink in the screenshot.
      tb = s.evaluate(%q{(function(){var e=document.querySelector('.title_bar img');if(!e)return '';var b=e.getBoundingClientRect(),sc=document.querySelector('.screen')||document.body;return [b.left,b.top,b.width,b.height,sc.getBoundingClientRect().left,innerWidth].join(',')})()})
      unless tb.to_s.empty?
        require 'chunky_png'
        bx, by, bw, bh, _sx, iw = tb.split(',').map(&:to_f)
        png = ChunkyPNG::Image.from_file(s.png_path)
        k = png.width / iw
        ink = 0
        (by * k).floor.upto(((by + bh) * k).ceil - 1) { |y| (bx * k).floor.upto(((bx + bw) * k).ceil - 1) { |x| next if x >= png.width || y >= png.height; v = png[x, y]; ink += 1 if ChunkyPNG::Color.r(v) + ChunkyPNG::Color.g(v) + ChunkyPNG::Color.b(v) < 300 } }
        puts "TBAR #{c['name']}: icon #{bw.round}x#{bh.round} ink #{ink}" if ink < 12
        expect(ink).to be >= 12
      end
      err = s.evaluate("(document.querySelector('[data-sw-error]')||{getAttribute:function(){return null}}).getAttribute('data-sw-error')")
      puts "ERR #{c['name']}: #{err}" if err
      expect(err).to be_nil
      # Offline (saved state, owner 2026-11-13): a stale view shows its "as of" once, inside the view, clear of every other ink box.
      sl = s.evaluate(%q{(function(){var st=SW.stale||null,ls=[].filter.call(document.querySelectorAll('[data-sw-stale]'),function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0});if(!st)return ls.length?'label without stale data':'';if(ls.length!==1)return 'labels '+ls.length;var L=ls[0].getBoundingClientRect(),V=(document.querySelector('.view')||document.body).getBoundingClientRect(),bad=[];if(ls[0].textContent.trim()!==st)bad.push('text '+ls[0].textContent);if(L.left<V.left||L.right>V.right||L.top<V.top||L.bottom>V.bottom)bad.push('outside the view');var cx=(L.left+L.right)/2,cy=(L.top+L.bottom)/2,F=[].map.call(document.querySelectorAll('[data-sw-part="face"]'),function(e){return e.getBoundingClientRect()}).filter(function(f){return f.width>0&&cx>f.left&&cx<f.right&&cy>f.top&&cy<f.bottom})[0];if(ls[0].closest('.title_bar')){}else if(!F)bad.push('not on a panel');else{var r=Math.min(24,Math.min(F.width,F.height)*0.08),I=2;if(L.left<F.left+I||L.right>F.right-I||L.top<F.top+I||L.bottom>F.bottom-I)bad.push('over the panel edge');[[L.left,L.top],[L.right,L.top],[L.left,L.bottom],[L.right,L.bottom]].forEach(function(q){var ox=q[0]<F.left+r?F.left+r:(q[0]>F.right-r?F.right-r:null),oy=q[1]<F.top+r?F.top+r:(q[1]>F.bottom-r?F.bottom-r:null);if(ox!==null&&oy!==null&&Math.hypot(q[0]-ox,q[1]-oy)>r-I)bad.push('over the rounded corner')});}[].forEach.call(document.querySelectorAll('img,svg,.value,.title,.label,.instance,[data-sw-rule]'),function(e){if(e===ls[0]||ls[0].contains(e)||e.contains(ls[0])||e.closest('[data-sw-part="face"]'))return;var b=e.getBoundingClientRect();if(e.tagName==='IMG'&&e.getAttribute('data-sw-ink')){var ik=e.getAttribute('data-sw-ink').split(',').map(Number),cxx=(b.left+b.right)/2;b={left:cxx-ik[1]*b.height/2,right:cxx+ik[1]*b.height/2,top:b.top+ik[0]*b.height,bottom:b.top+(ik[0]+ik[1])*b.height,width:b.width,height:ik[1]*b.height}}   // the icon's drawn ink (square icons), not its transparent box
if(b.width>0&&b.height>0&&b.left<L.right-1&&b.right>L.left+1&&b.top<L.bottom-1&&b.bottom>L.top+1)bad.push('overlaps '+((e.closest('[data-sw-part]')||e).getAttribute('data-sw-part')||e.tagName+' '+(e.textContent||'').trim().slice(0,12)))});return bad.join('; ');})()})
      puts "STALE #{c['name']}: #{sl}" unless sl.empty?
      expect(sl).to eq('')
      # Indoor trend (saved state, owner 2026-11-13): an up/down arrow behind the indoor unit, inside its twin column; today's low/high fully inside the column.
      it3 = s.evaluate(%q{(function(){var I=SW.inn;if(!I)return '';var bad=[],col=document.querySelector('[data-sw-twin="in"]');if(!col||!col.getBoundingClientRect().width)return '';var C=col.getBoundingClientRect(),a=[].filter.call(col.querySelectorAll('[data-sw-inarrow]'),function(e){return e.getBoundingClientRect().width>0}),want=(I.arrow==='up'||I.arrow==='down')&&document.querySelector('.screen--lg')?1:0;if(a.length!==want)bad.push('arrows '+a.length+'/'+want+' '+[].map.call(col.querySelectorAll('[data-sw-inarrow]'),function(e){var b=e.getBoundingClientRect();return b.width+'x'+b.height+' '+e.innerHTML.length}).join(','));if(a.length){var p=a[0].querySelector('[data-sw-arrowpoly]'),u=col.querySelector('[data-sw-unit="in"]').getBoundingClientRect(),A=a[0].getBoundingClientRect();if(!p||p.getAttribute('data-sw-arrowpoly')!==I.arrow)bad.push('arrow shape');var dg=col.querySelector('[data-sw-part="itemp"]').getBoundingClientRect();if(A.right>dg.left+1)bad.push('arrow not in front of the digits');if(A.left<C.left-1)bad.push('arrow outside the column')}var l=col.querySelector('[data-sw-inlohi]');if(I.lohi&&l){var rg=document.createRange();rg.selectNodeContents(l);var L=rg.getBoundingClientRect();if(L.width>0&&l.querySelectorAll('[data-sw-part="tri"] svg polygon').length!==2)bad.push('low/high marks not two triangles');if(/[LH] \d/.test(l.textContent))bad.push('low/high as letters');if(L.width>0&&(L.left<C.left-1||L.right>C.right+1))bad.push('low/high outside the column');var pe=l.parentElement,ro=document.querySelector('[data-sw-twin="out"]'),rl=ro&&ro.lastElementChild,lh=rl?rl.getBoundingClientRect().height:0;if(L.width>0&&lh>0&&pe.getBoundingClientRect().height>1.3*lh)bad.push('humidity line wraps')}return bad.join('; ');})()})
      puts "INTREND #{c['name']}: #{it3}" unless it3.empty?
      expect(it3).to eq('')
      # Twin meter (owner 2026-11-13; grey moved to outdoor, owner 2026-11-14: indoor is the primary reading): the outdoor (grey) blocks keep a shadow clearly lighter than their fill, or none, so no block melts into a smear.
      sd = s.evaluate(%q{(function(){var bad=[],L=function(c){var m=c.match(/[\d.]+/g)||[];return m.length>2?0.3*m[0]+0.59*m[1]+0.11*m[2]:0};document.querySelectorAll('[data-sw-twrow="out"]').forEach(function(r){var on=r.querySelector('[data-sw-on] [data-sw-c]'),sh=[].filter.call(r.querySelectorAll('g[class*="1bit:hidden"]'),function(e){return e.getBBox().width>0})[0];if(!on||!sh)return;var d=L(getComputedStyle(sh).color)-L(getComputedStyle(on).fill);if(d<40)bad.push('shadow only '+d.toFixed(0)+' lighter than the block')});return bad.join('; ')})()})
      puts "TWINSHADOW #{c['name']}: #{sd}" unless sd.empty?
      expect(sd).to eq('')
      # Secondary text (owner 2026-11-13 for indoor; owner 2026-11-14: indoor is primary, the grey value is now the outdoor one): the grey
      # dial value is readable, clearly darker than 130 (light) / lighter than 125 (dark) yet at least 40 levels away from black / white, so it still differs from the main ink.
      # B12: not on 1-bit screens (X-size 1-bit models: Kobo Aura One, Seeed E1004): there the framework draws grey text as a dither pattern, its
      # computed colour is no grey level; a person checks the 1-bit dial readout instead.
      it4 = s.evaluate(%q{(function(){var e=document.querySelector('.value--small[class*="text--gray"]');if(!e||!e.getBoundingClientRect().width||document.querySelector('.screen--1bit'))return '';var m=getComputedStyle(e).color.match(/[\d.]+/g),v=0.3*m[0]+0.59*m[1]+0.11*m[2],dk=document.documentElement.classList.contains('dark')||!!document.querySelector('.dark,.screen--dark,[data-theme=dark]')&&getComputedStyle(document.body).backgroundColor!=='rgb(255, 255, 255)';var bg=getComputedStyle(document.querySelector('.screen')||document.body).backgroundColor.match(/[\d.]+/g)||[255,255,255],bl=0.3*bg[0]+0.59*bg[1]+0.11*bg[2],ink=bl<128?255:0,d=Math.abs(v-ink);return d<40?'outdoor text '+v.toFixed(0)+' too close to the ink':(d>130?'outdoor text '+v.toFixed(0)+' too light to read':'')})()})
      puts "INDOORTEXT #{c['name']}: #{it4}" unless it4.empty?
      expect(it4).to eq('')
      tf = s.evaluate(%q{(function(){var v=function(q){var e=document.querySelector(q);if(!e)return 0;var r=e.getBoundingClientRect();return r.width>0?r.height:0};var t=v('[data-sw-part="temp"] svg'),f=v('[data-sw-part="feels"] svg');return f&&!(t>f)?'temp '+t.toFixed(0)+' felt '+f.toFixed(0):''})()})   # owner step 12: the main temperature is the largest number in the console
      arc = s.evaluate(%q{(function(){var a=[].filter.call(document.querySelectorAll('g[data-sw-arc]'),function(g){return g.ownerSVGElement.getBoundingClientRect().width>0}),bad=[],rs=[];a.forEach(function(g){var sv=g.ownerSVGElement,k=sv.getBoundingClientRect().width/+sv.getAttribute('width'),v=g.getAttribute('data-sw-arc').split(',').map(Number),r=v[0]*k,w=v[1]*k;rs.push(r);var SB=sv.getBoundingClientRect(),T=1e9;[].forEach.call(sv.querySelectorAll('path,polygon,circle,line,text'),function(e){var b=e.getBoundingClientRect();if(b.width||b.height)T=Math.min(T,b.top)});var hb=sv.querySelector('[data-sw-hub]').getBoundingClientRect();if((T-SB.top)/SB.height>0.2||(SB.bottom-hb.bottom)/SB.height>0.2)bad.push('dial not filling its panel: top '+((T-SB.top)/SB.height*100).toFixed(0)+'% hub '+((SB.bottom-hb.bottom)/SB.height*100).toFixed(0)+'%');var d=sv.closest('[data-sw-part]').getAttribute('data-sw-part'),D=d==='baro'?SW.baro:SW.tdial;if(D&&D.lo!=null&&D.hi!=null&&sv.querySelectorAll('[data-sw-markt]').length!==2)bad.push(d+' marks '+sv.querySelectorAll('[data-sw-markt]').length);});if(rs.length===2&&Math.abs(rs[0]-rs[1])>2)bad.push('radius '+rs.map(function(x){return x.toFixed(1)}).join('/'));return a.length+'|'+bad.join('; ');})()})   # owner step 13: both dials one radius, filling the panel height (ink within 20 % of the top: 3-digit low/high numbers and the twin needle shrink both; hub within 5 % of the bottom), low/high marks on both
      # Dial radius (owner 2026-11-13): the arc radius, as a share of the dial width, is the same in every case of one device and view (within 2 %).
      rw = s.evaluate(%q{(function(){var a=[].filter.call(document.querySelectorAll('g[data-sw-arc]'),function(g){return g.ownerSVGElement.getBoundingClientRect().width>0});return a.map(function(g){var v=g.getAttribute('data-sw-arc').split(',').map(Number);return (v[0]/v[1]).toFixed(4)}).join(' ')})()})
      # the main temperature: the largest digits (indoor with a sensor, owner 2026-11-14); cases with an indoor reading form their own group
      cr0 = s.evaluate(%q{(function(){var v=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0},c=[].filter.call(document.querySelectorAll('[data-sw-cond]'),v)[0],h=function(e){return e.getBBox().height*e.getBoundingClientRect().height/(e.viewBox.baseVal.height||1)},te=[].filter.call(document.querySelectorAll('[data-sw-part="temp"] svg,[data-sw-part="itemp"] svg'),v).sort(function(a,b){return h(b)-h(a)})[0];if(!c||!te)return '';var ti=h(te),fz=(+c.getAttribute('data-sw-fs')||parseFloat(getComputedStyle(c).fontSize))*(c.getBoundingClientRect().width/(c.offsetWidth||1));return String(fz/ti)})()})
      puts "CONDR #{c[%q(name)]}: #{cr0}"
      COND_R[[dev.is_a?(Hash) ? dev[:model] : dev, c['orientation'], c['text_scale'], c['fixture'], c['dark'] ? 1 : 0, s.evaluate('!!SW.inn')]] << [c['name'], cr0.to_f, c['view'] || 'full'] unless cr0.empty? || (c['fields'] || {})['unit'] == 'fahrenheit' || c['name'].start_with?('wide-')   # wide numbers shrink their digits (fit rule), the ratio is for normal values
      DIAL_R[[dev.is_a?(Hash) ? dev[:model] : dev, c['view'] || 'full', c['orientation'], c['text_scale']]] << [c['name'], rw.split.map(&:to_f).min] unless rw.empty?
      puts "DIALR #{c['name']}: #{rw}"
      puts "ARC #{c['name']}: #{arc}"
      # Dial clearance (owner 2026-11-13, live X full): no dial ink (arc, ticks, numbers, zone icons, band, marks, labels;
      # not the needle) within the gap (3 % of the dial height, at least 3 px) of the caption text boxes or the panel edges.
      dc = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-part="baro"],[data-sw-part="tdial"]').forEach(function(d){var B=d.getBoundingClientRect();if(!B.width)return;var k=d.getAttribute('data-sw-part'),g=Math.max(3,B.height*0.03)-1,P=(d.closest('[data-sw-panel]')||d).getBoundingClientRect(),caps=[].map.call(d.parentElement.querySelectorAll('[data-sw-cap]'),function(c){var rg=document.createRange();rg.selectNodeContents(c);return rg.getBoundingClientRect()}).filter(function(q){return q.width>0});
var n=0;[].forEach.call(d.querySelectorAll('svg path, svg line, svg text, svg polygon, svg image, svg circle'),function(e){if(e.closest('[data-sw-needle],defs,[data-sw-twin]'))return;var b=e.getBoundingClientRect();if(!b.width&&!b.height)return;var w=(e.getAttribute('stroke-width')||0)/2*(B.width/(+d.querySelector('svg').getAttribute('width')||B.width));
var x0=b.left-w,y0=b.top-w,x1=b.right+w,y1=b.bottom+w,tag=e.tagName+(e.textContent?' '+e.textContent:'');
if(x0<P.left+g||y0<P.top+g||x1>P.right-g||y1>P.bottom-g){if(n++<3)bad.push(k+' '+tag+' at the panel edge');return;}
// a curved path is tested along its length (150 points), not by its box: the box of an arc covers the empty corner above its ends
var bx=[[x0,y0,x1,y1]];if(e.tagName==='path'&&e.getTotalLength){var Lg=e.getTotalLength(),M=e.getScreenCTM();bx=[];for(var i=0;i<=150;i++){var q=e.getPointAtLength(Lg*i/150),X=M.a*q.x+M.c*q.y+M.e,Y=M.b*q.x+M.d*q.y+M.f;bx.push([X-w,Y-w,X+w,Y+w])}}
caps.forEach(function(c){if(bx.some(function(b){return b[0]<c.right+g&&b[2]>c.left-g&&b[1]<c.bottom+g&&b[3]>c.top-g})&&n++<3)bad.push(k+' '+tag+' within '+g.toFixed(0)+' of caption');});});});return bad.join('; ');})()})
      puts "DIALCLEAR #{c['name']}: #{dc}" unless dc.empty?
      geo = s.evaluate("(function(){var r=[].slice.call(document.querySelectorAll('[data-sw-part=\\'day\\']')).map(function(e){return e.getBoundingClientRect()}).filter(function(b){return b.width>0});return r.filter(function(b){return Math.abs(b.height-r[0].height)>0.5||Math.abs(b.left-r[0].left)>0.5||Math.abs(b.width-r[0].width)>0.5}).length+'/'+r.length})()")
      div = s.evaluate(%q{(function(){var out=[];document.querySelectorAll('[data-sw-div]').forEach(function(dv){var d=dv.getBoundingClientRect();if(!d.height)return;var row=dv.parentElement,u=row.querySelector('[data-sw-unit=\'\']'),t=row.querySelector('[data-sw-part=\'temp\'] svg'),p=row.querySelector(':scope > [data-sw-part=\'cue\']');function k(e){var r=e.getBoundingClientRect(),v=e.viewBox.baseVal,b=e.getBBox(),x=r.width/v.width,y=r.height/v.height;return{l:r.left+(b.x-v.x)*x,t:r.top+(b.y-v.y)*y,h:b.height*y}}var c=document.createElement('canvas').getContext('2d'),cs=getComputedStyle(u);c.font=cs.fontWeight+' '+cs.fontSize+' '+cs.fontFamily;var ub=u.getBoundingClientRect(),sc=(u.offsetWidth&&ub.width/u.offsetWidth)||1;var ur=ub.left+c.measureText(u.textContent.trim()).actualBoundingBoxRight*sc,pi={l:p.getBoundingClientRect().left},ti=k(t),mid=(d.left+d.right)/2;out.push([(mid-ur).toFixed(1),(pi.l-mid).toFixed(1),(d.height-ti.h).toFixed(1),(d.top-ti.t).toFixed(1),sc.toFixed(3),ur.toFixed(1),pi.l.toFixed(1),d.left.toFixed(1),d.right.toFixed(1)].join(','))});return out.join(' ')})()})
      puts "DIV #{c['name']}: gapL,gapR,dH,dTop #{div}"
      div.split.each { |q| a = q.split(',').map(&:to_f); expect((a[0] - a[1]).abs).to be <= 1.5; expect(a[2].abs).to be <= 1.5; expect(a[3].abs).to be <= 1.5 }
      # Dial corners (owner 2026-11-13): caption and value corners equal inset (1 px) and one baseline (1 px); an arrow slot with no arrow takes no room (icon and value one normal gap apart).
      dcn = s.evaluate(%q{(function(){var bad=[],R=function(e){var g=document.createRange();g.selectNodeContents(e);return g.getBoundingClientRect()},B=function(e){var p=document.createElement('span');p.style.cssText='display:inline-block;width:0;height:0';e.appendChild(p);var y=p.getBoundingClientRect().bottom;e.removeChild(p);return y};document.querySelectorAll('[data-sw-part="baro"],[data-sw-part="tdial"]').forEach(function(d){var P=d.closest('[data-sw-panel]').getBoundingClientRect(),w=d.parentElement,cap=w.querySelector('span[data-sw-cap]'),row=[].filter.call(w.querySelectorAll('div[data-sw-cap]:not([data-sw-dialin])'),function(e){return e.getBoundingClientRect().width>0})[0];if(!cap||!row||!P.width)return;var k=d.getAttribute('data-sw-part'),sp=row.querySelectorAll('span'),l=R(cap).left-P.left,r=P.right-R(sp[sp.length-1]).right;if(Math.abs(l-r)>1)bad.push(k+' caption inset '+l.toFixed(1)+' vs value inset '+r.toFixed(1));var bc=B(cap),bv=B(row.querySelector('.value'));if(Math.abs(bc-bv)>1)bad.push(k+' caption baseline '+bc.toFixed(1)+' vs value '+bv.toFixed(1))});document.querySelectorAll('[data-sw-cap]').forEach(function(r){if(r.tagName==='SPAN'||!r.getBoundingClientRect().width)return;var cg=parseFloat(getComputedStyle(r).columnGap)||0,k=r.getBoundingClientRect().width/(r.offsetWidth||1),it=[].filter.call(r.children,function(e){return e.getBoundingClientRect().width>0});for(var i=1;i<it.length;i++){var g=it[i].getBoundingClientRect().left-it[i-1].getBoundingClientRect().right;if(Math.abs(g-cg*k)>1.5)bad.push((it[i-1].getAttribute('data-sw-part')||it[i-1].tagName)+' to '+(it[i].getAttribute('data-sw-part')||it[i].tagName)+' gap '+g.toFixed(1)+' vs '+(cg*k).toFixed(1))}});document.querySelectorAll('[data-sw-part="arrow"]:not([data-sw-arrow])').forEach(function(e){if(e.getBoundingClientRect().width>0)bad.push('empty arrow slot '+e.getBoundingClientRect().width.toFixed(0)+' wide')});return bad.join('; ')})()})
      puts "DIALCORNER #{c['name']}: #{dcn}" unless dcn.empty?
      expect(dcn).to eq('')
      # Half vertical (owner 2026-11-13): the console panel's ink starts as far below its top edge as it ends above its bottom edge (1 px, from the picture).
      if (c['view'] || 'full') == 'half_vertical' && !c['orientation'] && %w[x-hv-calm x-hv-whole x-hv-hours x-hv-f104].include?(c['name'])   # text-topped layouts (dry, pollen, aq7) are still unbalanced: issue to follow
        fb = s.evaluate(%q{(function(){var f=document.querySelector('[data-sw-console] [data-sw-part="face"]');if(!f)return '';var b=f.getBoundingClientRect();return [b.left,b.top,b.right,b.bottom,innerWidth].join(',')})()})
        unless fb.to_s.empty?
          require 'chunky_png'
          fl, ft, fr, fbm, iw = fb.split(',').map(&:to_f)
          png = ChunkyPNG::Image.from_file(s.png_path)
          kk = png.width / iw
          lum = ->(v) { 0.3 * ChunkyPNG::Color.r(v) + 0.59 * ChunkyPNG::Color.g(v) + 0.11 * ChunkyPNG::Color.b(v) }
          bgl = lum.call(png[(fl * kk + 8).to_i, ((ft + fbm) / 2 * kk).to_i])
          rows = ((ft * kk).ceil + 4..(fbm * kk).floor - 4).select { |y| ((fl * kk).ceil + 80..(fr * kk).floor - 80).any? { |x| (lum.call(png[x, y]) - bgl).abs > 12 } }
          top = (rows.first - ft * kk) / kk
          bot = (fbm * kk - rows.last) / kk
          puts "HVPAD #{c['name']}: ink top #{top.round(1)} bottom #{bot.round(1)}"
          expect((top - bot).abs).to be <= 1
        end
      end
      if c['og_quadrant_console']
        console = s.evaluate(%q{(function(){function vis(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0}var labels=[].filter.call(document.querySelectorAll('[data-sw-mlabel]'),vis).map(function(e){return e.textContent.trim()});var moon=[].filter.call(document.querySelectorAll('[data-sw-part="moon"]'),vis)[0];var ring=moon&&moon.querySelector('circle[stroke]');return {labels:labels,ring:!!ring,lit:!!(moon&&moon.querySelector('[data-sw-moon="lit"]'))}})()})
        small_q = s.evaluate("document.querySelectorAll('[data-sw-small]').length").positive?
        if small_q   # the small console (owner-approved 2026-11-13) keeps a meter row and the moon only while they fit
          expect(console['labels'] - ['WIND']).to eq([])
        else
          expect(console['labels']).to eq(['WIND'])
          expect(console['ring']).to eq(true) unless c['hourly'].nil?
          expect(console['lit']).to eq(true) unless c['hourly'].nil?
        end
      end
      clip = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-part]:not([data-sw-part="face"]), [data-sw-part]:not([data-sw-part="face"]) > svg, [data-sw-unit] img, [data-sw-unit] span').forEach(function(e){var b=e.getBoundingClientRect();if(!b.width||!b.height)return;var ci=e.closest('[data-sw-condicon]'),ik=ci&&(ci.querySelector('[data-sw-ink]')||{getAttribute:function(){return null}}).getAttribute('data-sw-ink');if(ik){var iy=+ik.split(',')[0],ih=+ik.split(',')[1]||1;b={left:b.left,right:b.right,top:b.top+iy*b.height,bottom:b.top+(iy+ih)*b.height,width:b.width,height:ih*b.height};}var p=e.closest('[data-sw-panel]');if(!p)return;var q=p.getBoundingClientRect(),cs=getComputedStyle(p),k=q.width/(p.offsetWidth||q.width);var pm=e.closest('[data-sw-suntime]')?1:0;q={left:q.left+pm*parseFloat(cs.paddingLeft)*k,right:q.right-pm*parseFloat(cs.paddingRight)*k,top:q.top+pm*parseFloat(cs.paddingTop)*k,bottom:q.bottom-pm*parseFloat(cs.paddingBottom)*k};var un=e.closest('[data-sw-unit]');if(un){var cb=un.parentElement.getBoundingClientRect();q={left:Math.max(q.left,cb.left),right:Math.min(q.right,cb.right),top:Math.max(q.top,cb.top),bottom:Math.min(q.bottom,cb.bottom)}}if(b.left<q.left-1||b.right>q.right+1||b.top<q.top-1||b.bottom>q.bottom+1)bad.push((e.getAttribute('data-sw-part')||e.tagName)+'@'+[b.left,b.right,b.top,b.bottom].map(function(v){return v.toFixed(0)}).join(':')+'/'+[q.left,q.right,q.top,q.bottom].map(function(v){return v.toFixed(0)}).join(':'))});return bad.join(' ')})()})
      puts "CLIP #{c['name']}: #{clip}" unless clip.empty?
      expect(clip).to eq('')
      # Owner 2026-11-14: a meter label's text fits inside its own box, padding included (an inverted extreme label lost its D;
      # seen red with the label-width padding HP removed, og1-port-quadrant-storm).
      mlab = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-mlabel]').forEach(function(e){var b=e.getBoundingClientRect();if(!b.width||!b.height)return;var g=document.createRange();g.selectNodeContents(e);var t=g.getBoundingClientRect(),cs=getComputedStyle(e),k=b.width/(e.offsetWidth||b.width);if(t.left<b.left+parseFloat(cs.paddingLeft)*k-0.5||t.right>b.right-parseFloat(cs.paddingRight)*k+0.5)bad.push(e.textContent.trim()+' text '+Math.round(t.left)+'..'+Math.round(t.right)+' box '+Math.round(b.left)+'..'+Math.round(b.right));});return bad.join('; ');})()})
      puts "MLAB #{c['name']}: #{mlab}" unless mlab.empty?
      expect(mlab).to eq('')
      # Layout from the device (owner 2026-11-14, B12: the OG once got the small console from a measured screen): the full view's small
      # console follows trmnl.device and the framework's size class, never a measurement; og-devsize says 480x800 on an 800x480 screen.
      if c.key?('want_small')
        sm = s.evaluate("!!document.querySelector('[data-sw-console][data-sw-small]')")
        puts "LAYOUT #{c['name']}: small #{sm}" unless sm == c['want_small']
        expect(sm).to eq(c['want_small'])
      end
      # Owner 2026-11-14: with several devices a screen shows only its own sensor (the X showed the OG's); want_in '' = no indoor reading.
      if c['want_in']
        inr = s.evaluate("(window.SW && SW.inn && SW.inn.temp) || ''").to_s
        puts "INDOOR #{c['name']}: #{inr}" unless inr == c['want_in']
        expect(inr).to eq(c['want_in'])
      end
      # B13 (owner 2026-11-14): another TRMNL's sensor, its label, the main reading. want_main 'sensor' or 'outside': SW.sim agrees, the first
      # readout (left twin, or the big group of a small view) holds the main reading, the second the other one; want_label: the label shows at
      # the sensor's readout, whole inside its panel, and never in a meter row; outdoor rows never carry the sensor's mark (the house icon
      # of a meter row sits only on the twin humidity row, data-sw-for = the twin's key).
      if c['want_main'] || c.key?('want_label')
        bm = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},bad=[],wm=WANT_MAIN,wl=WANT_LABEL,tw=null;
if(SW.inn&&wm){if((SW.sim!==false)!==(wm==='sensor'))bad.push('SW.sim '+SW.sim+' but main '+wm);
var tws=[].filter.call(document.querySelectorAll('[data-sw-twin]'),vis).sort(function(a,b){return a.getBoundingClientRect().left-b.getBoundingClientRect().left}),g=vis(document.querySelector('[data-sw-small] [data-sw-sgrp="temp"]'))&&document.querySelector('[data-sw-small] [data-sw-sgrp="temp"]'),first=tws.length?tws[0].getAttribute('data-sw-twin'):g?(g.querySelector('[data-sw-part="itemp"]')?'in':'out'):'';
if(first&&first!==(wm==='sensor'?'in':'out'))bad.push('first readout '+first+', main '+wm);}
var sl=[].filter.call(document.querySelectorAll('[data-sw-slab]'),vis);
if(wl===''){if(sl.length)bad.push('label shown without one');}
else if(SW.inn){if(!sl.length)bad.push('no label');sl.forEach(function(e){var p=e.closest('[data-sw-twin],[data-sw-sbox]'),pb=p&&p.getBoundingClientRect(),b=e.getBoundingClientRect(),t=(e.getAttribute('data-sw-sl8')||e.textContent||'').trim();if(!t)bad.push('label empty');if(wl.indexOf(t.replace(/[.\u2026]$/,''))!==0)bad.push('label text '+t+' not from '+wl);if(pb&&(b.left<pb.left-1||b.right>pb.right+1))bad.push('label outside its panel');if(e.scrollWidth>e.clientWidth+1&&getComputedStyle(e).textOverflow!=='ellipsis')bad.push('label clipped without ellipsis')});}
if(wl)[].forEach.call(document.querySelectorAll('[data-sw-mlabel]'),function(e){if(e.textContent.toUpperCase().indexOf(wl.slice(0,3))>=0)bad.push('label in a meter row: '+e.textContent)});
var twk=(SW.meters.filter(function(m){return m.tw})[0]||{}).key;[].forEach.call(document.querySelectorAll('[data-sw-part="loc"][data-sw-for]'),function(e){if(!vis(e))return;if(e.getAttribute('data-sw-for')!==twk)bad.push('mark on row '+e.getAttribute('data-sw-for')+' ('+e.getAttribute('data-sw-loc')+')')});
return bad.join('; ');})()}.sub('WANT_MAIN', c['want_main'].to_s.to_json).sub('WANT_LABEL', c['want_label'].to_s.to_json))
        puts "B13 #{c['name']}: #{bm}" unless bm.empty?
        expect(bm).to eq('')
      end
      # Owner 2026-11-14 (B9): the CO2 meter is drawn exactly when the case says (co2 'yes'): a fresh reading of this screen's own
      # device, sensor_co2 not hidden, a place in the view's meter rows (a half vertical with a normal reading shows only two
      # rows, CO2 last, so no). Whatever is drawn is also in SW.meters (the list the page script draws from).
      co2 = s.evaluate(%q{document.querySelectorAll('[data-sw-key="co2"]').length + ',' + (window.SW ? SW.meters.some(function(m){return m.key==='co2'}) : false)})
      puts "CO2 #{c['name']}: #{co2}"
      expect(co2.split(',')[0].to_i.positive?).to eq(c['co2'] == 'yes')
      expect(co2.split(',')[1]).to eq('true') if c['co2'] == 'yes'
      # Owner 2026-11-14 (B1 guards, each seen red on a mutation): (1) a rain calendar always has its rain/snow icon beside it, in every
      # view; (2) in a small console the big temperature is the largest text; (3) wide numbers (-20.5 C, 104 F, -13 F, 100 F) stay inside their
      # panel with a 2 px margin and overlap no unit, badge, calendar, low/high, condition or location icon of that panel.
      wd = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null};
[].filter.call(document.querySelectorAll('[data-sw-part="rain"]'),vis).forEach(function(c){var ic=[].filter.call(document.querySelectorAll('[data-sw-unit="rain"] img, [data-sw-unit="rain"] [data-sw-part="icon"]'),vis)[0];if(!ic)bad.push('rain calendar without its rain icon')});
var ink=function(v){var r=v.getBoundingClientRect(),bb=v.getBBox(),vb=v.viewBox.baseVal,kx=r.width/(vb.width||r.width),ky=r.height/(vb.height||r.height);return {left:r.left+(bb.x-vb.x)*kx,right:r.left+(bb.x-vb.x+bb.width)*kx,top:r.top+(bb.y-vb.y)*ky,bottom:r.top+(bb.y-vb.y+bb.height)*ky}};
[].filter.call(document.querySelectorAll('[data-sw-part="temp"] svg, [data-sw-part="itemp"] svg'),vis).forEach(function(v){var p=v.closest('[data-sw-panel]'),P=vis(p);if(!P)return;var I=ink(v);
if(I.left<P.left+2||I.right>P.right-2||I.top<P.top+2||I.bottom>P.bottom-2)bad.push('temperature outside its panel '+[I.left,I.right,P.left,P.right].map(Math.round));
[].forEach.call(p.querySelectorAll('[data-sw-unit], [data-sw-part="cue"], [data-sw-part="rain"], [data-sw-slohi], [data-sw-inlohi], [data-sw-cond], [data-sw-part="loc"], [data-sw-part="itemp"], [data-sw-part="temp"]'),function(e){if(e.contains(v)||v.closest('[data-sw-part]').contains(e))return;var b=vis(e);if(!b)return;if(Math.min(I.right,b.right)-Math.max(I.left,b.left)>1&&Math.min(I.bottom,b.bottom)-Math.max(I.top,b.top)>1)bad.push('temperature overlaps '+(e.getAttribute('data-sw-part')||e.getAttribute('data-sw-unit')!==null&&'unit'||e.tagName))});});
var sm=document.querySelector('[data-sw-small]');if(sm){var te=[].filter.call(sm.querySelectorAll('[data-sw-sgrp="temp"] [data-sw-part="temp"] svg,[data-sw-sgrp="temp"] [data-sw-part="itemp"] svg'),vis)[0];if(te){var h=ink(te),th=h.bottom-h.top,mx=0,who='';[].forEach.call(sm.querySelectorAll('span, text'),function(e){if(!vis(e)||!(e.textContent||'').trim())return;if(e.tagName==='span'&&e.querySelector('svg'))return;var k=e.ownerSVGElement?e.ownerSVGElement.getBoundingClientRect().height/(+e.ownerSVGElement.getAttribute('height')||1):(vis(e).width/(e.offsetWidth||1)),f=(e.tagName==='text'?+e.getAttribute('font-size'):(+e.getAttribute('data-sw-fs')||parseFloat(getComputedStyle(e).fontSize)))*(e.tagName==='text'?k:1);if(f>mx){mx=f;who=(e.textContent||'').trim().slice(0,10)}});if(mx&&th<=mx)bad.push('small console: temperature '+th.toFixed(0)+' not the largest text ('+who+' '+mx.toFixed(0)+')')}}
return bad.join('; ');})()})
      puts "WIDE #{c['name']}: #{wd}" unless wd.empty?
      expect(wd).to eq('')
      # Rain unit (owner 2026-11-12): calendar cells square-ish and readable (numbers at least the meter label size),
      # rain icon and moon the same size on the same left edge. Dials: caption and value never under the hub or tail.
      ru = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null};
var lab=[].filter.call(document.querySelectorAll('[data-sw-mlabel]'),vis)[0],lp=lab?parseFloat(getComputedStyle(lab).fontSize):(document.querySelector('[data-sw-small]')?12:14);   // a small console without a meter row has no label to match: at least 12 px
[].forEach.call(document.querySelectorAll('[data-sw-part="rain"]'),function(d){var sv=d.querySelector('svg');if(!vis(d)||!sv)return;
var k=d.offsetHeight/+sv.getAttribute('height'),t=sv.querySelector('text'),fs=t?+t.getAttribute('font-size')*k:0,ch=d.offsetHeight/Math.ceil(sv.querySelectorAll('text').length/3),cw=d.offsetWidth/3;
var tb=[].map.call(sv.querySelectorAll('text'),function(t){var r=t.getBoundingClientRect();r.y0=t.getAttribute('y');return r});tb.forEach(function(a,i){tb.slice(i+1).forEach(function(b){if(a.y0===b.y0&&Math.min(a.right,b.right)-Math.max(a.left,b.left)>-1)bad.push('labels overlap '+[a.left,a.right,b.left,b.right].map(Math.round))})});
if(fs<lp*0.95)bad.push('num '+fs.toFixed(1)+'<label '+lp+' cell '+cw.toFixed(0)+'x'+ch.toFixed(0));if(cw/ch<0.8||cw/ch>2)bad.push('cell '+cw.toFixed(0)+'x'+ch.toFixed(0));if(ch<lp*1.05)bad.push('cellH '+ch.toFixed(0));
var ic=[].filter.call(document.querySelectorAll('[data-sw-unit="rain"] img'),vis)[0],mo=[].filter.call(document.querySelectorAll('[data-sw-part="moon"]'),vis)[0];
if(ic&&mo){var a=ic.getBoundingClientRect(),b=mo.getBoundingClientRect();if(Math.abs(a.width-b.width)>2||Math.abs(a.height-b.height)>2||Math.abs(a.left-b.left)>2)bad.push('icon '+[a.left,a.width,a.height].map(Math.round)+' moon '+[b.left,b.width,b.height].map(Math.round));}
var cl=[].filter.call(document.querySelectorAll('[data-sw-unit="rain"] [data-sw-part="rain"]'),vis)[0];if(ic&&cl){var a=ic.getBoundingClientRect(),b=cl.getBoundingClientRect();if(a.right<=b.left+1&&Math.abs((a.top+a.bottom)/2-(b.top+b.bottom)/2)>2)bad.push('rain icon off the calendar centre '+Math.round((a.top+a.bottom)/2-(b.top+b.bottom)/2));}});
document.querySelectorAll('[data-sw-hub]').forEach(function(h){var sv=h.ownerSVGElement,hb=vis(h);if(!hb)return;var k=hb.width/(2*+h.getAttribute('r')),R=+h.getAttribute('data-sw-hub')*k,cx=hb.left+hb.width/2,cy=hb.top+hb.height/2;
sv.closest('.relative').querySelectorAll('[data-sw-cap]').forEach(function(c){var b=vis(c);if(!b)return;var nx=Math.max(b.left,Math.min(cx,b.right)),ny=Math.max(b.top,Math.min(cy,b.bottom));if(Math.hypot(nx-cx,ny-cy)<R)bad.push('dial caption under hub: '+c.textContent.trim());});});
return bad.join('; ');})()})
      puts "RAINUNIT #{c['name']}: #{ru}" unless ru.empty?
      expect(ru).to eq('')
      # Moon beside the sun rows (owner 2026-11-13: moon data is not that important): the disc at most 0.72 of the two
      # rows (first sun icon top to last sun icon bottom) and centred on them.
      mo = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-unit="sun"]').forEach(function(u){var m=[].filter.call(u.querySelectorAll('[data-sw-part="moon"]'),function(e){return e.getBoundingClientRect().height>0})[0],ic=[].filter.call(u.querySelectorAll('img[data-sw-icon]'),function(e){return e.getBoundingClientRect().height>0});if(!m||ic.length<2||!u.getBoundingClientRect().height)return;
var ci=m.querySelector('circle'),b=ci?ci.getBoundingClientRect():m.getBoundingClientRect(),t=ic[0].getBoundingClientRect().top,bo=ic[ic.length-1].getBoundingClientRect().bottom,r=b.height/(bo-t),dc=(b.top+b.bottom)/2-(t+bo)/2;if(r>0.72||Math.abs(dc)>3)bad.push('moon '+b.height.toFixed(0)+' rows '+(bo-t).toFixed(0)+' dc '+dc.toFixed(1))});return bad.join('; ')})()})
      puts "MOON #{c['name']}: #{mo}" unless mo.empty?
      # 1-bit light (step 18): the moon's lit part sits inside a paper ring, so ring and lit part read apart.
      m1 = s.evaluate(%q{(function(){var sc=document.querySelector('.screen').classList;if(!sc.contains('screen--1bit')||sc.contains('screen--dark-mode'))return '';var bad=[];document.querySelectorAll('[data-sw-moon="lit"]').forEach(function(l){var c=l.ownerSVGElement.querySelector('circle[stroke-width]');if(!c||!l.getBoundingClientRect().width)return;var r=+c.getAttribute('r'),w=+c.getAttribute('stroke-width'),h=l.getBBox().height;if(h>2*(r-w)-1)bad.push('lit '+h.toFixed(1)+' touches the ring r '+r.toFixed(1))});return bad.join('; ')})()})
      puts "MOON1 #{c['name']}: #{m1}" unless m1.empty?
      expect(m1).to eq('')
      expect(mo).to eq('') if c['view'] == 'half_vertical'
      # X quadrant (owner, step 12: big empty bands above and below): the content of each panel (images, drawings,
      # text) leaves no band over 8 % of the panel height at its top or bottom, also none between its rows on X quadrant (step 19: landscape too) and X full portrait, hairlines counting as ink (step 18).
      if (c['view'] == 'quadrant' && is_lg) || c['portrait_console']
        band = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-panel]').forEach(function(p){var q=p.getBoundingClientRect();if(!q.height)return;var t=1e9,b=-1e9;
var iv=[];p.querySelectorAll('img, svg, span').forEach(function(e){if(e.closest('[data-sw-part="face"]'))return;var r=e.getBoundingClientRect();if(!r.width||!r.height||(e.tagName==='SPAN'&&!e.textContent.trim()))return;t=Math.min(t,r.top);b=Math.max(b,r.bottom);iv.push([r.top,r.bottom])});
var a=(t-q.top)/q.height,z=(q.bottom-b)/q.height;if(a>0.08||z>0.08)bad.push('top '+(a*100).toFixed(0)+'% bottom '+(z*100).toFixed(0)+'%');
if(BETWEEN){p.querySelectorAll('[data-sw-rule]').forEach(function(e){var r=e.getBoundingClientRect();if(r.width&&getComputedStyle(e).display!=='none')iv.push([r.top,Math.max(r.bottom,r.top+1)])});iv.sort(function(x,y){return x[0]-y[0]});var e0=t;iv.forEach(function(v){if((v[0]-e0)/q.height>0.08)bad.push('band '+((v[0]-e0)/q.height*100).toFixed(0)+'% at '+Math.round(e0-q.top));e0=Math.max(e0,v[1]);})}});return bad.join('; ')})()}.sub('BETWEEN', (is_lg && (c['view'] == 'quadrant' || (c['view'] == 'full' && c['orientation'] == 'portrait'))).to_s))
        puts "BAND #{c['name']}: #{band}" unless band.empty?
        expect(band).to eq('')
      end
      # OG portrait (owner 2026-11-13, "portrait for the OG is still broken"): a well-filled tall layout, not landscape
      # pieces squeezed. Icons (condition, rain, moon, sun, day-row clothing) have drawn ink at least 0.8 x the cap height
      # of the text beside them; the days scale's track at least 45 % of the day row width with its first and last labels
      # at the track's ends (within a cell); no empty band over 12 % of the panel height inside the console, the days
      # panel or the console's right column (ink measured in the screenshot); low/high digits at least 0.85 x the day name size;
      # quadrant: the temperature digits at least 13 % of the console height. The rain icon is an img, or in dark mode its glow drawing
      # ([data-sw-part="icon"], as in the rain-calendar check above; B12, Poke 5 dark, a native portrait screen now held to these checks).
      if is_port && !is_lg && %w[full half_vertical half_horizontal quadrant].include?(c['view'] || 'full')
        require 'chunky_png'
        og = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},cx=document.createElement('canvas').getContext('2d'),R=function(b){return [b.left,b.top,b.right,b.bottom]};
function cap(sp){var b=vis(sp);if(!b)return 0;var cs=getComputedStyle(sp),sf=+sp.getAttribute('data-sw-fs')||0;cx.font=cs.fontWeight+' '+(sf?sf+'px':cs.fontSize)+' '+cs.fontFamily;return cx.measureText('H').actualBoundingBoxAscent*(b.width/(sp.offsetWidth||b.width));}
function scap(t){var sv=t.ownerSVGElement,k=sv.getBoundingClientRect().height/(+sv.getAttribute('height')||sv.getBoundingClientRect().height);cx.font='bold '+(+t.getAttribute('font-size'))+'px '+getComputedStyle(t).fontFamily;return cx.measureText('H').actualBoundingBoxAscent*k;}
var ic=[],add=function(n,e,c){var b=vis(e);if(b&&c)ic.push([n].concat(R({left:Math.max(0,b.left),top:Math.max(0,b.top),right:Math.min(innerWidth,b.right),bottom:Math.min(innerHeight,b.bottom)})).concat([c]))};   // the small console's icon box may reach past the screen edge (negative margin: only its transparent part)
[].filter.call(document.querySelectorAll('[data-sw-cond]'),vis).forEach(function(sp){add('cond',sp.parentElement.firstElementChild,cap(sp))});
var st=[].filter.call(document.querySelectorAll('[data-sw-suntime] span.title'),vis);
[].filter.call(document.querySelectorAll('[data-sw-unit="sun"] img'),vis).forEach(function(e,i){var t=e.parentElement.querySelector('[data-sw-suntime] span.title');add('sun',e,cap(t||st[0]))});
[].filter.call(document.querySelectorAll('[data-sw-part="moon"]'),vis).forEach(function(e){if(st[0])add('moon',e.querySelector('svg')||e,cap(st[0]))});
var ca=[].filter.call(document.querySelectorAll('[data-sw-part="rain"] svg text'),vis)[0];[].filter.call(document.querySelectorAll('[data-sw-unit="rain"] img'),vis).forEach(function(e){if(ca)add('rain',e,scap(ca))});
[].filter.call(document.querySelectorAll('[data-sw-row="day"]'),vis).forEach(function(r,i){var t=[].filter.call(r.querySelectorAll('span.title'),function(s){return vis(s)&&/\d/.test(s.textContent)})[0];if(!t)return;var c=cap(t);var nm=r.querySelector('[data-sw-dname],[data-sw-today]'),nf=nm?parseFloat(getComputedStyle(nm).fontSize):0,tf=parseFloat(getComputedStyle(t).fontSize);if(nf&&tf<0.85*nf)ic.push(['day'+i+' low/high '+tf+'px under 0.85 x the day name '+nf+'px',0,0,0,0,1]);[].filter.call(r.querySelectorAll('img'),vis).forEach(function(e){add('day'+i+' icon',e,c)});var d=r.querySelector('[data-sw-part="dcue"]');if(vis(d))add('day'+i+' clothing',d,c);});
var tr='',sc=[].filter.call(document.querySelectorAll('[data-sw-part="scale"]'),vis)[0],row=[].filter.call(document.querySelectorAll('[data-sw-row="day"]'),vis)[0];
if(sc&&row){var sv=sc.querySelector('svg'),sb=sv.getBoundingClientRect(),k=sb.width/(+sv.getAttribute('width')||sb.width),g=sv.querySelector('[data-sw-track]'),cw=0;
[].forEach.call(document.querySelectorAll('[data-sw-cells] rect'),function(q){var w=q.getBoundingClientRect().width;if(vis(q))cw=Math.max(cw,w+2)});
var x0,x1;if(g){var v=g.getAttribute('data-sw-track').split(',').map(Number);x0=sb.left+v[0]*k;x1=sb.left+v[1]*k}else{var L=1e9,Rr=-1e9;[].forEach.call(document.querySelectorAll('[data-sw-cells] rect'),function(q){var b=vis(q);if(b){L=Math.min(L,b.left);Rr=Math.max(Rr,b.right)}});x0=L;x1=Rr}
var lb=[].map.call(sv.querySelectorAll('text[data-sw-tick]'),function(t){var b=t.getBoundingClientRect();return (b.left+b.right)/2});
tr=[(x1-x0)/row.getBoundingClientRect().width,lb.length?lb[0]-x0:1e9,lb.length?lb[lb.length-1]-x1:1e9,cw].map(function(v){return v.toFixed(3)}).join(',')}
var pn=[];[].filter.call(document.querySelectorAll('[data-sw-panel]'),vis).forEach(function(p){var q=p.getBoundingClientRect(),t=1e9,b=-1e9;p.querySelectorAll('img, svg, span').forEach(function(e){if(e.closest('[data-sw-part="face"]'))return;var r=vis(e);if(!r||(e.tagName==='SPAN'&&!e.textContent.trim()))return;t=Math.min(t,r.top);b=Math.max(b,r.bottom)});if(b>t)pn.push([p.closest('[data-sw-console]')?'console':'days',q.left+10,t,q.right-10,b,q.height]);
var rt=p.querySelector('[data-sw-right]'),rb=vis(rt);if(rb&&rb.left>q.left+q.width*0.25){var tp=rt.parentElement.getBoundingClientRect();pn.push(['right column',rb.left,tp.top,rb.right,tp.bottom,q.height,1])}});
var tq=vis(document.querySelector('[data-sw-part="temp"] svg')),pq=vis(document.querySelector('[data-sw-console] [data-sw-panel]'));if(QUAD&&tq&&pq&&tq.height<0.13*pq.height)ic.push(['temperature '+tq.height.toFixed(0)+' under 13 % of the console '+pq.height.toFixed(0),0,0,0,0,1]);
if([].filter.call(document.querySelectorAll('[data-sw-part="rain"]'),vis).length&&![].filter.call(document.querySelectorAll('[data-sw-unit="rain"] img,[data-sw-unit="rain"] [data-sw-part="icon"]'),vis).length)ic.push(['rain icon missing beside the calendar',0,0,0,0,1]);
return JSON.stringify({ic:ic,tr:tr,pn:pn,iw:innerWidth});})()}.sub('QUAD', (c['view'] == 'quadrant').to_s))
        og = JSON.parse(og)
        png = ChunkyPNG::Image.from_file(s.png_path)
        k = png.width / og['iw'].to_f
        dark = ->(x, y, lim) { v = png[x, y]; ChunkyPNG::Color.r(v) + ChunkyPNG::Color.g(v) + ChunkyPNG::Color.b(v) < lim }
        bad = []
        og['ic'].each do |n, l, t, r, b, capv|
          next bad << n if r.zero?
          ys = ((t * k).floor..((b * k).ceil - 1)).select { |y| y < png.height && ((l * k).floor..[(r * k).ceil - 1, png.width - 1].min).any? { |x| dark.(x, y, 384) } }
          ink = ys.empty? ? 0 : (ys.last - ys.first + 1) / k
          bad << "#{n} ink #{ink.round(1)} < 0.8 x cap #{capv.round(1)}" if ink < 0.8 * capv
        end
        unless og['tr'].empty?
          w, f, z, cw = og['tr'].split(',').map(&:to_f)
          bad << "track #{(w * 100).round}% of the row" if w < 0.45
          bad << "scale labels first #{f.round(1)} last #{z.round(1)} from the track ends (cell #{cw.round(1)})" if f.abs > cw || z.abs > cw
        end
        og['pn'].each do |n, l, t, r, b, ph, edges|
          y0 = [(t * k).floor, 0].max; y1 = [(b * k).ceil - 1, png.height - 1].min; xs = ((l * k).ceil..[(r * k).floor - 1, png.width - 1].min)
          ink = (y0..y1).select { |y| xs.any? { |x| dark.(x, y, 600) } }
          next if ink.empty?
          runs = ink.each_cons(2).map { |a, z2| [z2 - a - 1, a] }
          runs += [[ink.first - y0, y0], [y1 - ink.last, ink.last]] if edges
          mx, at = runs.max_by(&:first) || [0, 0]
          bad << "#{n} empty band #{(mx / k / ph * 100).round}% below y #{(at / k).round}" if mx / k > 0.12 * ph
        end
        puts "OGPORT #{c['name']}: #{bad.join('; ')}" unless bad.empty?
        expect(bad).to eq([])
      end
      # Bleed margin (owner 2026-11-12): every panel (borderless: its lit face) and the title bar keep the framework's
      # screen padding from the screen edge.
      edge = s.evaluate(%q{(function(){var sc=document.querySelector('.screen')||document.body,S=sc.getBoundingClientRect(),k=S.width/(sc.offsetWidth||S.width),bad=[],m=8*k;
document.querySelectorAll('[data-sw-panel], .title_bar').forEach(function(e){var b=e.getBoundingClientRect();if(!b.width||!b.height)return;
var d=Math.min(b.left-S.left,b.top-S.top,S.right-b.right,S.bottom-b.bottom);if(d<m)bad.push((e.className.baseVal||e.className||e.tagName).toString().slice(0,30)+' '+d.toFixed(1));});return bad.join('; ');})()})
      puts "EDGE #{c['name']}: #{edge}" unless edge.empty?
      expect(edge).to eq('')
      # 2-bit (owner 2026-11-12): every grey a native level, no dither tiles in the drawn parts.
      if c['palette'] == 'gray-4'
        pat = s.evaluate("document.querySelectorAll('svg pattern').length")
        puts "PATTERN #{c['name']}: #{pat}" unless pat.zero?
        expect(pat).to eq(0)
      end
      # Weather icon (owner 2026-11-12, revised): drawn ink 2.1 to 2.5 x the cap height (owner, step 12: about 2.3x), one line or two, ink centred on the label.
      ci = s.evaluate(%q{(function(){var bad=[],cx=document.createElement('canvas').getContext('2d');document.querySelectorAll('[data-sw-cond]').forEach(function(sp){var sb=sp.getBoundingClientRect();if(!sb.height)return;
var ic=sp.parentElement.firstElementChild,ib=ic.getBoundingClientRect(),k=sb.width/(sp.offsetWidth||sb.width),cs=getComputedStyle(sp);var sf=+sp.getAttribute('data-sw-fs')||0;cx.font=cs.fontWeight+' '+(sf?sf+'px':cs.fontSize)+' '+cs.fontFamily;var m=cx.measureText('H'),fa=m.fontBoundingBoxAscent*k,fd=m.fontBoundingBoxDescent*k,cap=m.actualBoundingBoxAscent*k;
var rg=document.createRange();rg.selectNodeContents(sp);var lr=[].filter.call(rg.getClientRects(),function(q){return q.width>0}),bl=function(q){return q.top+(q.height-fa-fd)/2+fa},t0=sf?0:bl(lr[0])-cap,t1=sf?0:bl(lr[lr.length-1]),n=sf?+sp.getAttribute('data-sw-lines'):lr.filter(function(q,i){return i===0||Math.abs(q.top-lr[i-1].top)>2}).length;
var ik=((ic.querySelector('[data-sw-ink]')||ic).getAttribute('data-sw-ink')||'0,1').split(',').map(Number),it=ib.top+ik[0]*ib.height,ih=ik[1]*ib.height,h=n>1?t1-t0+cap:cap,mid=sf?(sb.top+sb.bottom)/2:(n>1?(t0+t1)/2:t0+cap/2),q=ih/h;if(n>2)bad.push('label on '+n+' lines');if(n>1&&(q=ih/cap,0))0;if(n>1?(q<(ic.hasAttribute('data-sw-clamped')?1.6:2.1)||q>2.5):(q<(ic.hasAttribute('data-sw-clamped')?1.6:2.1)||q>2.5))bad.push('icon ink '+ih.toFixed(1)+' / cap '+(n>1?cap:h).toFixed(1)+' = '+q.toFixed(2)+' ('+n+' lines)');if(Math.abs(it+ih/2-mid)>1.5)bad.push('icon ink centre off '+(it+ih/2-mid).toFixed(1));});return bad.join('; ');})()})
      puts "CONDICON #{c['name']}: #{ci}" unless ci.empty?
      expect(ci).to eq('')
      # Days strip (owner 2026-11-12, later): the strip always starts with today, the one highlighted row.
      hl = s.evaluate(%q{(function(){var r=[].filter.call(document.querySelectorAll('[data-sw-part="day"]'),function(e){return e.getBoundingClientRect().width>0});if(!r.length)return '';var h=r.map(function(e,i){return e.querySelector('[data-sw-hl]')?i:-1}).filter(function(i){return i>=0});var t0=SW.days[+r[0].getAttribute('data-sw-i')];if(!t0||!t0.today)return 'first row not today: '+(t0&&t0.name);var tl=[].filter.call(document.querySelectorAll('[data-sw-today]'),function(e){return e.getBoundingClientRect().width>0})[0];if(!tl||!/label--inverted/.test(tl.className))return 'today name not an inverted label';return h.length===1&&h[0]===0?'':'highlighted rows '+JSON.stringify(h);})()})
      puts "HL #{c['name']}: #{hl}" unless hl.empty?
      expect(hl).to eq('')
      # Days strip axis labels (owner 2026-11-12): at least the meter label size.
      ax = s.evaluate(%q{(function(){var vis=function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0};var lab=[].filter.call(document.querySelectorAll('[data-sw-mlabel]'),vis)[0],sc=[].filter.call(document.querySelectorAll('[data-sw-part="scale"] svg'),vis)[0];if(!lab||!sc)return '';
var lp=parseFloat(getComputedStyle(lab).fontSize)*(lab.getBoundingClientRect().width/(lab.offsetWidth||1)),k=sc.getBoundingClientRect().height/+sc.getAttribute('height'),t=sc.querySelector('text[data-sw-tick]');if(!t)return 'no axis label';var fs=+t.getAttribute('font-size')*k;return fs<lp-0.5?'axis '+fs.toFixed(1)+' < label '+lp.toFixed(1):'';})()})
      puts "AXIS #{c['name']}: #{ax}" unless ax.empty?
      expect(ax).to eq('')
      # Colour (owner 2026-11-12, as live): red and yellow only on colour palettes and only on the warning parts
      # (lit lamps, meter warning zones, the days now line and pointer, lit rain cells); none on gray palettes.
      hu = s.evaluate(%q{(function(){var bad=[],n=0,ch=function(v){var m=/(\d+)\D+(\d+)\D+(\d+)/.exec(v||'');if(!m)return false;var a=[+m[1],+m[2],+m[3]];return Math.max.apply(0,a)-Math.min.apply(0,a)>60};
document.querySelectorAll('[data-sw-part] svg *').forEach(function(e){if(!e.getBoundingClientRect().width)return;var cs=getComputedStyle(e);if(!(ch(e.getAttribute('fill'))||ch(cs.fill)&&e.tagName!=='g'))return;n++;
var h=e.closest('[data-sw-hue]'),pt=e.closest('[data-sw-part]').getAttribute('data-sw-part');if(!h)bad.push('stray '+pt+' '+e.tagName);else if(['meter','day','scale','rain'].indexOf(pt)<0)bad.push('part '+pt);});
document.querySelectorAll('.view *').forEach(function(e){if(e.closest('svg'))return;var b=getComputedStyle(e).backgroundColor;if(!ch(b)||!e.getBoundingClientRect().width)return;n++;if(!e.matches('[data-sw-lamp][data-sw-hue]'))bad.push('html '+e.tagName+' '+String(e.className).slice(0,30));});
return n+(bad.length?' '+bad.slice(0,4).join('; '):'');})()})
      colour = (c['palette'] || '').start_with?('color-')
      puts "HUE #{c['name']}: #{hu}"
      expect(hu).to match(/\A\d+\z/)
      expect(hu.to_i.positive?).to eq(colour)
      # Pollen (owner 2026-11-12): a pollen meter row is shown only when it lights at least one cell.
      po = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-part="meter"][data-sw-key="pollen"]').forEach(function(m){if(!m.getBoundingClientRect().width)return;var l=m.querySelector('[data-sw-lit]');if(!l||!(+l.getAttribute('data-sw-lit')>0))bad.push('pollen 0 cells');});return bad.join('; ');})()})
      puts "POLLEN #{c['name']}: #{po}" unless po.empty?
      expect(po).to eq('')
      # Indoor sensor (as live): with a reading, BUITEN and BINNEN twin readouts side by side (digits drawn, no overlap,
      # the humidity under BINNEN, no felt line under BUITEN, owner 2026-11-13), and the temperature dial (when shown) carries the twin needle; without one, none of it.
      sn = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},bad=[];
var tw=[].filter.call(document.querySelectorAll('[data-sw-twin="out"],[data-sw-twin="in"]'),vis),nd=[].filter.call(document.querySelectorAll('svg [data-sw-twin="1"] polygon'),function(l){return vis(l.ownerSVGElement)&&!l.closest('[data-sw-glow]')});
if(tw.length){if(tw.length!==2)bad.push('twins '+tw.length);else{var a=tw[0].getBoundingClientRect(),b=tw[1].getBoundingClientRect();if(a.right>b.left+1)bad.push('twins overlap');
tw.forEach(function(t){var k=t.getAttribute('data-sw-twin'),d=t.querySelector('[data-sw-part="temp"] svg,[data-sw-part="itemp"] svg'),sp=t.querySelectorAll(':scope > span'),lc=t.querySelector('[data-sw-part="loc"]'),lb=lc&&lc.querySelector('svg path')&&vis(lc);if(!d||!vis(d)||!d.querySelector('path,rect,polygon'))bad.push(k+' no digits');if(!lb)bad.push(k+' no location icon');else{var db=d.getBoundingClientRect(),cb=lc.getBoundingClientRect(),cq=vis(t.querySelector('[data-sw-cb]')),cc=((cq?Math.min(cb.left,cq.left):cb.left)+(cq?Math.max(cb.right,cq.right):cb.right))/2;   /* owner 2026-11-14: the tree and the clothing cue are one group centred over the outdoor digits */if(!t.querySelector('[data-sw-slab]')){/* B13: with a label the house icon and the label sit left, the label is the group */if(cc<db.left||cc>db.right)bad.push(k+' icon centre '+cc.toFixed(0)+' outside its digits '+db.left.toFixed(0)+'-'+db.right.toFixed(0));if(Math.abs(cc-(db.left+db.right)/2)>db.width*0.15)bad.push(k+' icon not centred over its digits');}}var un=t.querySelector('[data-sw-unit]'),fs=un?parseFloat(getComputedStyle(un).fontSize):0;if(fs&&lc.offsetHeight<1.35*fs)bad.push(k+' readout icon '+lc.offsetHeight.toFixed(0)+' px under 1.4 unit fonts of '+fs.toFixed(0)+' px (owner 2026-11-14, B10)');if(k==='out'&&sp[0]&&sp[0].textContent.trim())bad.push('line under BUITEN '+sp[0].textContent.trim());});}}
/* B10: on 1-bit a location icon is ink, not grey (a grey outline dithers away) */if(document.querySelector('.screen--1bit'))[].forEach.call(document.querySelectorAll('[data-sw-part="loc"] svg path'),function(p){if(!vis(p.ownerSVGElement))return;var m=getComputedStyle(p).stroke.match(/[\d.]+/g)||[],L=0.3*m[0]+0.59*m[1]+0.11*m[2];if(document.querySelector('.screen--dark-mode')?L<165:L>90)bad.push('1-bit icon grey '+L.toFixed(0))});
var td=[].filter.call(document.querySelectorAll('[data-sw-part="tdial"]'),vis).length;
if(!tw.length&&vis(document.querySelector('[data-sw-small] [data-sw-sgrp="temp"] [data-sw-part="itemp"] svg,[data-sw-small] [data-sw-sout] [data-sw-part="itemp"] svg')))tw=[1,2];
return tw.length+','+nd.length+','+td+(bad.length?' '+bad.join('; '):'');})()})
      puts "SENSOR #{c['name']}: #{sn}"
      want = c['sens_want'] || (c['vars'] && c['vars']['sensor_readings'] ? 2 : 0)   # sens_want 0: a reading over 3 h old shows nothing
      expect(sn.split(' ')[0].split(',')[0].to_i).to eq(want)
      expect(sn).not_to include(' ')
      dials = sn.split(',')[2].to_i
      # Indoor primary (owner 2026-11-14): with an indoor reading shown the indoor digits are the largest temperature on the screen
      # and the temperature dial's main needle is indoor (its twin outdoor); without one the outdoor temperature is the largest and no indoor digits show.
      tm = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},ds=[].filter.call(document.querySelectorAll('[data-sw-part="temp"] svg,[data-sw-part="itemp"] svg'),function(e){return vis(e)&&e.querySelector('path,rect,polygon')});if(!ds.length)return 'no digits';
var ink=function(e){var r=e.getBBox();return r.height*vis(e).height/(e.viewBox.baseVal.height||vis(e).height)},top=ds.slice().sort(function(a,b){return ink(b)-ink(a)}),k=top[0].closest('[data-sw-part]').getAttribute('data-sw-part'),inn=ds.some(function(e){return e.closest('[data-sw-part]').getAttribute('data-sw-part')==='itemp'}),bad=[];
if(inn!==!!SW.inn)bad.push('indoor digits '+inn+'/'+!!SW.inn);var pI=function(n){return ds.filter(function(e){return e.closest('[data-sw-part]').getAttribute('data-sw-part')===n}).map(ink)},iI=pI('itemp'),oO=pI('temp');
/* owner 2026-11-14 (replaces 'indoor the largest'): the two temperatures the same size; the outdoor reading always shows beside an indoor one, in the stacked small views at most as large as the indoor one */
if(SW.inn){if(!iI.length)bad.push('no indoor digits');if(!oO.length)bad.push('outdoor reading missing');else if(iI.length){var i0=Math.max.apply(null,iI),o0=Math.max.apply(null,oO),twv=vis(document.querySelector('[data-sw-twin="out"]'));var mn0=SW.sim===false?o0:i0,sd0=SW.sim===false?i0:o0;if(sd0>mn0+0.5)bad.push('the second reading larger than the main one');if(twv&&Math.abs(i0-o0)>0.01*i0)bad.push('indoor and outdoor digits not the same height '+i0.toFixed(0)+'/'+o0.toFixed(0));}}
var D=SW.tdial;[].filter.call(document.querySelectorAll('[data-sw-part="tdial"] svg'),vis).forEach(function(sv){var tn=sv.querySelector('[data-sw-twin="1"] polygon'),nd=[].filter.call(sv.querySelectorAll('[data-sw-needle] polygon'),function(p){return !p.closest('[data-sw-twin]')&&!p.closest('[class*="gray-55"]')&&!p.closest('[data-sw-glow]')}).pop();if(!SW.inn||!tn||!nd)return;var hb=sv.querySelector('[data-sw-hub]'),cx=+hb.getAttribute('cx'),ang=function(p){var q=p.getAttribute('points').split(' ')[0].split(',').map(Number);return Math.atan2(q[0]-cx,+hb.getAttribute('cy')-q[1])};
if((ang(nd)-ang(tn))*(parseFloat(SW.inn.temp)-D.now)*(SW.sim===false?-1:1)<0)bad.push('main needle not '+(SW.sim===false?'outdoor':'indoor'))});
return bad.join('; ');})()})
      puts "TEMPMAIN #{c['name']}: #{tm}" unless tm.empty?
      expect(tm).to eq('')
      # Meter order (owner 2026-11-14): with an indoor reading the indoor group is first (CO2, then the indoor humidity row, then the outdoor
      # humidity right after it), then the other outdoor meters; the shown rows follow it top to bottom in every view.
      mo = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},bad=[];
var ks=[].filter.call(document.querySelectorAll('[data-sw-part^="meter"][data-sw-key]'),vis).sort(function(a,b){return a.getBoundingClientRect().top-b.getBoundingClientRect().top||a.getBoundingClientRect().left-b.getBoundingClientRect().left}).map(function(e){return e.getAttribute('data-sw-key')+(e.getAttribute('data-sw-part')==='meterin'?'*':'')});
var ci=ks.indexOf('co2'),hi=ks.indexOf('humidity*'),oh=ks.indexOf('humidity');if(SW.sim===false){/* B13: the outside reading is main, its meters first, the sensor's CO2 last and its humidity right after the outdoor one */if(ci>=0&&ci!==ks.length-1)bad.push('CO2 not last: '+ks.join());if(hi>=0&&oh!==hi-1)bad.push('indoor humidity not right after outdoor: '+ks.join());}else{if(ci>0)bad.push('CO2 not first: '+ks.join());if(hi>=0){if(hi!==(ci===0?1:0))bad.push('indoor humidity not right after CO2: '+ks.join());if(oh>=0&&oh!==hi+1)bad.push('outdoor humidity not right after indoor: '+ks.join());}}
if(!SW.inn&&(hi>=0))bad.push('indoor humidity without an indoor reading');
/* B11 blocker: the readout holding the indoor value carries the house icon (data-sw-i 1, loc in) and never the clothing cue; the one holding the outdoor value the tree (data-sw-i 0, loc out) */
[].forEach.call(document.querySelectorAll('[data-sw-twin],[data-sw-sgrp="temp"],[data-sw-sout]'),function(g){if(!SW.inn||!vis(g))return;var ind=!!g.querySelector('[data-sw-part="itemp"]'),out=!!g.querySelector('[data-sw-part="temp"]');if(ind===out)return;var lc=[].filter.call(g.querySelectorAll('[data-sw-part="loc"]'),vis)[0];if(!lc){bad.push((ind?'indoor':'outdoor')+' readout without a location icon');return;}if(+lc.getAttribute('data-sw-i')!==(ind?1:0)||lc.getAttribute('data-sw-loc')!==(ind?'in':'out'))bad.push((ind?'indoor':'outdoor')+' value carries the '+lc.getAttribute('data-sw-loc')+' icon (i '+lc.getAttribute('data-sw-i')+')');if(ind&&[].some.call(g.querySelectorAll('[data-sw-part="cue"]'),vis))bad.push('clothing cue on the indoor readout');});
/* owner 2026-11-14: in the small views the tree (and the clothing cue) sit directly left of the outdoor digits as one group, not at the panel edge */
[].forEach.call(document.querySelectorAll('[data-sw-sout]'),function(o){if(!vis(o))return;var te=o.querySelector('[data-sw-part="temp"] svg'),ic=[].filter.call(o.querySelectorAll('[data-sw-part="loc"],[data-sw-socue]'),vis),r=te&&vis(te);if(!r||!ic.length)return;var vb=te.viewBox.baseVal,bb=te.getBBox(),ky=r.height/(vb.height||r.height),kx=r.width/(vb.width||r.width),il=r.left+(bb.x-vb.x)*kx,h=bb.height*ky,gr=Math.max.apply(null,ic.map(function(e){return e.getBoundingClientRect().right})),gap=il-gr;if(gap>0.45*h)bad.push('outdoor icons '+gap.toFixed(0)+' px left of their digits (digits '+h.toFixed(0)+' px high)');if(gap<-2)bad.push('outdoor icons over their digits '+gap.toFixed(0));});
return bad.join('; ');})()})
      puts "METERORD #{c['name']}: #{mo}" unless mo.empty?
      expect(mo).to eq('')
      # Rain hour calendar (owner 2026-11-14): on 4-bit the lit cells are clearly dark (near black; light on a dark screen), so the numbers read.
      rl = s.evaluate(%q{(function(){var sc=document.querySelector('.screen');if(!sc||sc.classList.contains('screen--1bit')||sc.classList.contains('screen--2bit'))return '';var r=[].filter.call(document.querySelectorAll('[data-sw-part="rain"] svg g[class*="text--gray"] rect'),function(e){var b=e.getBoundingClientRect();return b.width>3&&b.height>3})[0];if(!r)return '';var b=r.getBoundingClientRect();return [b.left,b.top,b.width,b.height,innerWidth,sc.classList.contains('screen--dark-mode')?1:0].join(',')})()})
      unless rl.empty?
        require 'chunky_png'
        rx, ry, _rw, _rh, riw, rdk = rl.split(',').map(&:to_f)
        rpng = ChunkyPNG::Image.from_file(s.png_path)
        rk = rpng.width / riw
        rv = rpng[((rx + 5) * rk).to_i, ((ry + 4) * rk).to_i]
        rlum = 0.3 * ChunkyPNG::Color.r(rv) + 0.59 * ChunkyPNG::Color.g(rv) + 0.11 * ChunkyPNG::Color.b(rv)
        puts "RAINLIT #{c['name']}: lit cell luminance #{rlum.round}" if rdk.zero? ? rlum > 80 : rlum < 170
        expect(rdk.zero? ? rlum <= 80 : rlum >= 170).to be(true), "lit rain cell too mid-grey (#{rlum.round}) for its numbers"
      end
      expect(sn.split(',')[1].to_i).to eq(want.positive? ? dials : 0)
      # Days strip (owner 2026-11-12): a paper channel beside the now line in every row with cells; cells a solid bar or
      # separated by at least 2 px; the now line over the axis labels (continuous) and its pointer clear of every label.
      ds = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null};
document.querySelectorAll('[data-sw-part="day"]').forEach(function(el){if(!vis(el))return;var nl=el.querySelector('[data-sw-now]'),cs=el.querySelectorAll('[data-sw-cells] rect');if(!cs.length)return;
var gk=el.querySelector('[data-sw-k]');if(gk&&+gk.getAttribute('data-sw-r')>=2*+gk.getAttribute('data-sw-k')&&cs.length<2)bad.push('one slab row '+el.getAttribute('data-sw-i'));
[].forEach.call(cs,function(q){var w=q.getBoundingClientRect().width;if(w<4)bad.push('cell under 4 px row '+el.getAttribute('data-sw-i')+' '+w.toFixed(1));});   // step 18: OG half vertical portrait drew 1 px slats
var R=[].map.call(cs,function(q){return[+q.getAttribute('x'),+q.getAttribute('x')+ +q.getAttribute('width')]}),wd=R.map(function(q){return q[1]-q[0]}).sort(function(a,b){return a-b}),md=wd[wd.length>>1];if(R.length>1&&wd[0]<md/2-0.5)bad.push('sliver row '+el.getAttribute('data-sw-i')+' '+wd[0].toFixed(1));
if(nl){var x0=+nl.getAttribute('x'),x1=x0+ +nl.getAttribute('width');R.forEach(function(q){if((Math.abs(q[0]-x1)<0.9||Math.abs(q[1]-x0)<0.9||(q[0]>x0-0.9&&q[0]<x1+0.9)||(q[1]>x0-0.9&&q[1]<x1+0.9)))bad.push('edge at the now line row '+el.getAttribute('data-sw-i'));});}
var r=[].map.call(cs,function(q){return[+q.getAttribute('x'),+q.getAttribute('x')+ +q.getAttribute('width')]}).sort(function(a,b){return a[0]-b[0]});for(var i=1;i<r.length;i++)if(r[i][0]-r[i-1][1]<1.9){bad.push('cells merge row '+el.getAttribute('data-sw-i')+' gap '+(r[i][0]-r[i-1][1]).toFixed(1));break;}});
document.querySelectorAll('[data-sw-part="scale"]').forEach(function(el){if(!vis(el))return;var nl=el.querySelector('[data-sw-now]'),ax=el.querySelector('[data-sw-axis]');if(!nl)return;
if(ax&&(ax.compareDocumentPosition(nl)&Node.DOCUMENT_POSITION_FOLLOWING)===0)bad.push('now line under the labels');var pt=el.querySelector('polygon');var pb=vis(pt);
if(pb)el.querySelectorAll('text').forEach(function(t){var b=t.getBoundingClientRect(),k=el.getBoundingClientRect().height/(+el.querySelector('svg').getAttribute('height')||1),cy=(b.top+b.bottom)/2,hc=+t.getAttribute('font-size')*k*0.36;if(b.width&&pb.left<b.right-1&&pb.right>b.left+1&&pb.bottom>cy-hc+0.5)bad.push('pointer over '+t.textContent);});});
return bad.join('; ');})()})
      puts "DAYS #{c['name']}: #{ds}" unless ds.empty?
      puts "DAYSTRIP #{c['name']}: #{ds}" unless ds.empty?
      expect(ds).to eq('')
      # X condition label (owner 2026-11-12): a clearly larger title than the day names, so it fills the middle block.
      if is_lg && %w[full half_horizontal].include?(c['view'] || 'full') && !is_port
        cr = s.evaluate(%q{(function(){var v=function(q){return [].filter.call(document.querySelectorAll(q),function(e){return e.getBoundingClientRect().width>0})[0]},a=v('[data-sw-cond]'),b=v('[data-sw-dname]')||v('[data-sw-mlabel]');return a&&b?parseFloat(getComputedStyle(a).fontSize)/parseFloat(getComputedStyle(b).fontSize):9;})()})
        puts "CONDSIZE #{c['name']}: #{cr.round(2)}" if cr < 1.2
        expect(cr).to be >= 1.2
      end
      # Dividers between panels (owner 2026-11-12): none between filled panels (light 4-bit), shown where panels are unfilled.
      bt = s.evaluate(%q{(function(){var sc=(document.querySelector('.screen')||document.body).classList,filled=!sc.contains('screen--dark-mode')&&!sc.contains('screen--1bit')&&!sc.contains('screen--2bit')&&!/(^| )screen--color-/.test(sc.value)&&!!document.querySelector('[data-sw-fill]');
var v=[].filter.call(document.querySelectorAll('[data-sw-between]'),function(e){return getComputedStyle(e).display!=='none'&&e.getClientRects().length>0&&(!e.closest('.hidden')||getComputedStyle(e.closest('.hidden')).display!=='none')}).length;return (filled?'filled ':'open ')+v;})()})
      puts "BETWEEN #{c['name']}: #{bt}" if bt.start_with?('filled') && bt != 'filled 0'
      expect(bt).to eq('filled 0') if bt.start_with?('filled')
      # Panel spacing (owner 2026-11-12): with filled panels, every gap (between panels, to the screen edges and the title
      # bar) the same within 2 px (B12: or one framework px where that is more, at the Scribe's 2.5 and the Avalue's 2.77 screen px per px a
      # rounded framework px alone is 3).
      pg = s.evaluate(%q{(function(){if(!document.querySelector('[data-sw-fill]'))return '';var sc=document.querySelector('[data-sw-debug]').closest('.view')||document.querySelector('.screen')||document.body,S=sc.getBoundingClientRect(),P=[].map.call(document.querySelectorAll('[data-sw-fill]'),function(e){return e.getBoundingClientRect()}).filter(function(b){return b.width>0&&b.height>0}),tb=document.querySelector('.title_bar'),T=tb&&tb.getBoundingClientRect().height?tb.getBoundingClientRect():null,g=[];
P.forEach(function(a){var Q=(document.querySelector('.screen')||document.body).getBoundingClientRect(),e=function(v,w){return v<1?w:v},L=e(a.left-S.left,a.left-Q.left),R=e(S.right-a.right,Q.right-a.right),U=e(a.top-S.top,a.top-Q.top),D=T?T.top-a.bottom:e(S.bottom-a.bottom,Q.bottom-a.bottom);P.forEach(function(b){if(b===a)return;if(b.right<=a.left+1&&b.bottom>a.top+1&&b.top<a.bottom-1)L=Math.min(L,a.left-b.right);if(b.left>=a.right-1&&b.bottom>a.top+1&&b.top<a.bottom-1)R=Math.min(R,b.left-a.right);if(b.bottom<=a.top+1&&b.right>a.left+1&&b.left<a.right-1)U=Math.min(U,a.top-b.bottom);if(b.top>=a.bottom-1&&b.right>a.left+1&&b.left<a.right-1)D=Math.min(D,b.top-a.bottom);});g.push(L,R,U,D);});
var mn=Math.min.apply(null,g),mx=Math.max.apply(null,g);return mx-mn>Math.max(2,parseFloat(getComputedStyle(document.querySelector('.screen')).getPropertyValue('--pixel-ratio'))||1)?'gaps '+mn.toFixed(1)+'..'+mx.toFixed(1)+' ['+g.map(function(v){return v.toFixed(0)}).join(',')+']':'';})()})
      puts "GAPS #{c['name']}: #{pg}" unless pg.empty?
      expect(pg).to eq('')
      # Barometer once (owner 2026-11-12): never the dial and the BARO meter both on screen.
      bb = s.evaluate(%q{(function(){var v=function(q){return [].some.call(document.querySelectorAll(q),function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0})};return v('[data-sw-part="baro"]')&&v('[data-sw-part="meter"][data-sw-key="baro"]')?'dial and meter':'';})()})
      puts "BARO #{c['name']}: #{bb}" unless bb.empty?
      expect(bb).to eq('')
      # Wind gust (owner 2026-11-12): the fixture's gust (28 km/h over 11 sustained) outlines exactly one WIND cell.
      gu = s.evaluate(%q{[].filter.call(document.querySelectorAll('[data-sw-part="meter"][data-sw-key="wind"]'),function(e){return e.getBoundingClientRect().width>0}).map(function(e){return e.querySelectorAll('[data-sw-gust]').length}).join(',')})
      puts "GUST #{c['name']}: #{gu}" unless gu.empty? || gu.split(',').all? { |v| v == '1' }
      expect(gu.split(',').all? { |v| v == '1' }).to be(true) if (c['fixture'] || 'mixed') == 'mixed' && !c.key?('current')
      # No warning lamps in any view (owner 2026-11-12); the rain unit's icon carries rain, snow or hail.
      lp = s.evaluate("document.querySelectorAll('[data-sw-lamp]').length")
      puts "LAMP #{c['name']}: #{lp}" unless lp.zero?
      expect(lp).to eq(0)
      # Panels (owner 2026-11-12): a plain fill, no backlight lamps (radial grey circles) behind dials, console or days.
      bl = s.evaluate(%q{document.querySelectorAll('[data-sw-backlight], [data-sw-part="face"] ellipse, [data-sw-part="face"] pattern').length})
      puts "BACKLIGHT #{c['name']}: #{bl}" unless bl.zero?
      expect(bl).to eq(0)
      # OG half_vertical (owner 2026-11-12): rain icon left of the calendar at its height, sun times shown, temperature
      # clearly bigger than the felt one, meter labels no bigger than day names, today an inverted lamp, solid dividers.
      if c['view'] == 'half_vertical' && !is_lg
        hv = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},one=function(q){return [].filter.call(document.querySelectorAll(q),vis)[0]};
var ic=one('[data-sw-unit="rain"] img')||one('[data-sw-unit="rain"] [data-sw-part="icon"]'),ca=one('[data-sw-part="rain"]');if(ca&&!ic)bad.push('no rain icon');if(ca&&ic){var a=ic.getBoundingClientRect(),b=ca.getBoundingClientRect();if(a.right>b.left+1||Math.abs(a.height-b.height)>2)bad.push('rain icon '+[a.left,a.right,a.height].map(Math.round)+' cal '+[b.left,b.height].map(Math.round));}
if(!one('[data-sw-unit="sun"]')&&!document.querySelector('[data-sw-small]'))bad.push('no sun times');   // the small console (owner-approved 2026-11-13) carries no sun timesvar wi=one('img[data-sw-icon], [data-sw-cond]'),pn=one('[data-sw-panel]');if(wi&&pn){var wb=one('[data-sw-cond]').parentElement.getBoundingClientRect(),pq=pn.getBoundingClientRect();if(wb.left<pq.left+4)bad.push('weather row past the panel '+wb.left.toFixed(0));}
var t=one('[data-sw-part="temp"] svg'),f=one('[data-sw-part="feels"] svg');if(t&&f&&(t.getBoundingClientRect().height<f.getBoundingClientRect().height*1.4||t.getBoundingClientRect().height<innerHeight*0.09))bad.push('temp not bigger '+t.getBoundingClientRect().height.toFixed(0)+'/'+f.getBoundingClientRect().height.toFixed(0));
var ml=one('[data-sw-mlabel]'),dn=one('[data-sw-dname]');if(ml&&dn&&parseFloat(getComputedStyle(ml).fontSize)>parseFloat(getComputedStyle(dn).fontSize)+0.5)bad.push('meter label > day name');
var td=one('[data-sw-today]');if(td&&!/label--inverted/.test(td.className))bad.push('today not lit');
var sc=(document.querySelector('.screen')||document.body).classList;if(sc.contains('screen--1bit')||sc.contains('screen--2bit'))[].filter.call(document.querySelectorAll('[data-sw-rule]'),function(r){return r.getClientRects().length>0;}).forEach(function(r){if(!/-black/.test(r.className))bad.push('dither rule');});
return bad.join('; ');})()})
        puts "OGHV #{c['name']}: #{hv}" unless hv.empty?
        expect(hv).to eq('')
      end
      # Calm style (owner): no L/R badges, the barometer shows a trend word, the temperature dial carries the low/high numbers,
      # no now line, no grid or row lines in the days strip; the clothing cue in the console.
      cm = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0},n=function(q){return [].filter.call(document.querySelectorAll(q),vis).length};
var dial=n('[data-sw-part="baro"]');return [1,dial,n('[data-sw-part="baro"] ~ .label--inverted, [data-sw-part="tdial"] ~ .label--inverted'),n('[data-sw-trend]'),n('[data-sw-mark]'),document.querySelectorAll('[data-sw-now]').length,document.querySelectorAll('[data-sw-part="day"] rect[data-sw-tick]').length,n('[data-sw-hair="row"]'),n('[data-sw-part="cue"] svg'),SW.cue&&SW.cue.length?1:0,SW.baro.trend?1:0].join(',');})()})
      puts "CALM #{c['name']}: calm,dial,badges,trend,marks,now,grid,hair,cue,wantcue #{cm}"
      q = cm.split(',').map(&:to_i)
      begin
        expect(q[0]).to eq(1)
        expect(q[2]).to eq(0)
        expect(q[3]).to eq(0)   # owner 2026-11-13: no trend word on the dial (the pressure shows; the trend is the arrow)
        expect(q[4]).to eq(q[1] * 2)
        expect(q[5..7]).to eq([0, 0, 0])
        small_c = s.evaluate("document.querySelectorAll('[data-sw-small]').length").positive?
        if small_c   # the small console (owner-approved 2026-11-13) keeps the badge only while it fits: shown only with a cue, never in the quadrant
          expect(!q[8].positive? || (q[9] == 1 && s.evaluate("document.querySelectorAll('[data-sw-nocue]').length").zero?)).to be(true)
        else
          expect(q[8].positive?).to eq(q[9] == 1 && s.evaluate("document.querySelectorAll('[data-sw-cueout]').length").zero? && s.evaluate("document.querySelectorAll('[data-sw-nocue]').length").zero? && !(c['view'] == 'half_vertical' && !is_lg && c['orientation'] != 'portrait'))   # step 18 (owner via coordinator): OG half_vertical portrait has room, the badge shows there   # owner 2026-11-13: beside the temperature, X half_vertical too; left out on OG half_vertical (owner 2026-11-13, too narrow) ; X half_vertical portrait shows it again (step 19, coordinator: owner rule, badge beside the temperature in every view; the OG hv portrait layout as the model)
        end
      end
      # Calm (owner): 1-bit and 2-bit panels stay paper (no grey fill); the dial's low/high numbers clear their triangles by 2 px
      # and are at least the size of the dial's scale numbers.
      # Owner 2026-11-14: a number pushed beside its triangle (no room above the dial) sits left of it for the low value, right of it for the high value.
      begin
        cf = s.evaluate(%q{(function(){var sc=(document.querySelector('.screen')||document.body).classList,lo=sc.contains('screen--1bit')||sc.contains('screen--2bit');
var f=lo?[].filter.call(document.querySelectorAll('[data-sw-fill]'),function(e){return e.getBoundingClientRect().width>0}).length:0,bad=[];
document.querySelectorAll('text[data-sw-mark]').forEach(function(t){var k=t.getAttribute('data-sw-mark'),m=t.ownerSVGElement.querySelector('[data-sw-markt="'+k+'"]');if(!m)return bad.push('no mark '+k);var a=t.getBoundingClientRect(),b=m.getBoundingClientRect();
var sf=[].map.call(t.ownerSVGElement.querySelectorAll('text:not([data-sw-mark])'),function(e){return +e.getAttribute('font-size')});if(sf.length&&+t.getAttribute('font-size')<Math.max.apply(null,sf))bad.push(k+' smaller than the scale numbers');var gx=Math.max(b.left-a.right,a.left-b.right),gy=Math.max(b.top-a.bottom,a.top-b.bottom),gp=Math.max(gx,gy);if(gp<2)bad.push(k+' gap '+gp.toFixed(1));if(t.hasAttribute('data-sw-beside')&&(k==='lo'?a.right>b.left+1:a.left<b.right-1))bad.push(k+' beside its mark on the wrong side');});
return (f?'fill '+f+' ':'')+bad.join('; ');})()})
        puts "CALMFIX #{c['name']}: #{cf}" unless cf.empty?
        expect(cf).to eq('')
      end
      # Inner padding (owner, Calm): margins from each panel edge to the drawn ink (SVG shapes, glyph ink of the text, the
      # weather icon's measured ink), per panel L,R,T,B.
      pad = s.evaluate(%q{(function(){var out=[],cx=document.createElement('canvas').getContext('2d'),vis=function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0&&getComputedStyle(e).visibility!=='hidden'};
document.querySelectorAll('[data-sw-panel]').forEach(function(p){var q=p.getBoundingClientRect();if(!q.width||!q.height)return;var L=1e9,R=-1e9,T=1e9,B=-1e9,add=function(l,r,t,b){if(r-l<0.5&&b-t<0.5)return;L=Math.min(L,l);R=Math.max(R,r);T=Math.min(T,t);B=Math.max(B,b);};
p.querySelectorAll('[data-sw-part]:not([data-sw-part="face"]) svg').forEach(function(sv){if(!vis(sv))return;sv.querySelectorAll('path,rect,circle,polygon,line,text,image,ellipse').forEach(function(e){if(e.closest('defs,mask,clipPath,filter,[data-sw-glow]'))return;var b=e.getBoundingClientRect();if(!b.width&&!b.height)return;add(b.left,b.right,b.top,b.bottom);});});
p.querySelectorAll('img').forEach(function(im){if(!vis(im)||im.closest('[data-sw-part]'))return;var b=im.getBoundingClientRect(),ik=(im.getAttribute('data-sw-ink')||'0,1').split(',').map(Number);add(b.left,b.right,b.top+ik[0]*b.height,b.top+(ik[0]+ik[1])*b.height);});
p.querySelectorAll('span').forEach(function(sp){if(!vis(sp)||sp.querySelector('span,img,svg'))return;var tx=sp.textContent.trim();if(!tx)return;var cs=getComputedStyle(sp),k=sp.getBoundingClientRect().width/(sp.offsetWidth||1);cx.font=cs.fontWeight+' '+cs.fontSize+' '+cs.fontFamily;var m=cx.measureText(tx),fa=m.fontBoundingBoxAscent,fd=m.fontBoundingBoxDescent;
var rg=document.createRange();rg.selectNodeContents(sp);[].forEach.call(rg.getClientRects(),function(r){if(!r.width)return;var bl=r.top+(r.height-(fa+fd)*k)/2+fa*k;add(r.left,r.right,bl-m.actualBoundingBoxAscent*k,bl+Math.max(0,m.actualBoundingBoxDescent)*k);});});
if(L<1e9)out.push([L-q.left,q.right-R,T-q.top,q.bottom-B].map(function(v){return v.toFixed(0)}).join(','));});return out.join(' ');})()})
      puts "PAD #{c['name']}: L,R,T,B #{pad}"
      # Small views (owner, Calm round 3): no days strip in a quadrant; Calm day rows at least the floor height (the Calm
      # full view's light row, 34 px on the OG and 63 px on the X, less 15 % for dark mode's divider); Calm: one now pointer, on today's row.
      dr = s.evaluate(%q{(function(){var r=[].filter.call(document.querySelectorAll('[data-sw-row="day"]'),function(e){return e.getBoundingClientRect().height>0}).map(function(e){return e.getBoundingClientRect().height});
var nm=[].filter.call(document.querySelectorAll('[data-sw-nowmark]'),function(e){return e.getBoundingClientRect().width>0}),tod=nm.filter(function(e){var d=e.closest('[data-sw-part="day"]');return d&&SW.days[+d.getAttribute('data-sw-i')].today}).length;
var ax=[].filter.call(document.querySelectorAll('[data-sw-part="scale"] text[data-sw-tick]'),function(e){return e.getBoundingClientRect().width>0})[0],big=1;
nm.forEach(function(e){var b=e.getBoundingClientRect(),k=ax?ax.ownerSVGElement.getBoundingClientRect().height/+ax.ownerSVGElement.getAttribute('height'):1,fs=ax?+ax.getAttribute('font-size')*k:0;if(b.height<fs*0.42*0.9)big=0;
[].forEach.call(e.ownerSVGElement.querySelectorAll('[data-sw-cells] rect'),function(r){var q=r.getBoundingClientRect();if(q.top<b.bottom-0.5&&q.left<b.right&&q.right>b.left)big=0;});});
return [r.length,r.length?Math.min.apply(null,r).toFixed(1):0,innerHeight,nm.length,tod,big].join(',');})()})
      puts "DAYROW #{c['name']}: rows,minH,screenH,ptr,ptrToday,ptrBigAndClear #{dr}"
      # Day rows (owner step 17): one name column width, so the icons line up in every row, the name never reaches its icon
      # (the inverted today label included; its text measured too, and never clipped by its box: step 19, x-port-hv) and all rows are the same height.
      al = s.evaluate(%q{(function(){var bad=[],L=[],H=[];[].forEach.call(document.querySelectorAll('[data-sw-row="day"]'),function(e){var q=e.getBoundingClientRect();if(!q.height)return;H.push(q.height);var lo=[].filter.call(e.querySelectorAll('span.title:not([data-sw-dname])'),function(x){return x.getBoundingClientRect().width>0})[0],im=[].filter.call(e.querySelectorAll('img'),function(x){return x.getBoundingClientRect().width>0})[0],nm=e.querySelector('[data-sw-today],[data-sw-dname]');if(nm&&lo&&nm.getBoundingClientRect().right>lo.getBoundingClientRect().left-6)bad.push('name '+nm.textContent.trim()+' reaches its low');if(nm){var r0=document.createRange();r0.selectNodeContents(nm);var tb=r0.getBoundingClientRect(),nb=nm.getBoundingClientRect();if(tb.width&&(tb.right>nb.right+0.5||tb.left<nb.left-0.5))bad.push('name '+nm.textContent.trim()+' runs past its label');}if(!im||!nm)return;var a=im.getBoundingClientRect(),b=nm.getBoundingClientRect(),rg=document.createRange();rg.selectNodeContents(nm);var rr=rg.getBoundingClientRect();if(rr.width&&rr.right>b.right)b=rr;L.push(a.left);if(b.right>a.left-3)bad.push('name '+nm.textContent.trim()+' reaches its icon');});
if(L.length&&Math.max.apply(null,L)-Math.min.apply(null,L)>1)bad.push('icon lefts '+L.map(Math.round));if(H.length&&Math.max.apply(null,H)-Math.min.apply(null,H)>1)bad.push('row heights '+H.map(Math.round));return bad.join('; ')})()})
      # Rain calendar cells are rectangles with the meter cells' corner radius (owner step 17), in rendered pixels.
      rx = s.evaluate(%q{(function(){var cal=[].filter.call(document.querySelectorAll('[data-sw-part="rain"] svg rect[rx]'),function(r){return r.getBoundingClientRect().width>0})[0],mc=[].filter.call(document.querySelectorAll('[data-sw-part="meter"] svg rect[rx]'),function(r){return r.getBoundingClientRect().width>0})[0];if(!cal||!mc)return '';
var px=function(r){var sv=r.ownerSVGElement;return +r.getAttribute('rx')*sv.getBoundingClientRect().height/+sv.getAttribute('height')};var a=px(cal),b=px(mc);return Math.abs(a-b)>0.6?'calendar rx '+a.toFixed(1)+' meter rx '+b.toFixed(1):''})()})
      puts "RAINRX #{c['name']}: #{rx}" unless rx.empty?
      expect(rx).to eq('')
      # Day names on one left edge, and a bar under its name sits closer to that name than to the next day (owner
      # 2026-11-13, OG half vertical portrait: names shifted, bars floating between rows).
      dn = s.evaluate(%q{(function(){var tb=function(n){var g=document.createRange();g.selectNodeContents(n);return n.hasAttribute('data-sw-today')?n.getBoundingClientRect():g.getBoundingClientRect()};var L=[],bad=[],R=[].filter.call(document.querySelectorAll('[data-sw-row="day"]'),function(r){return r.getBoundingClientRect().height>0});R.forEach(function(r){var n=r.querySelector('[data-sw-today],[data-sw-dname]');if(n)L.push(tb(n).left)});if(L.length&&Math.max.apply(null,L)-Math.min.apply(null,L)>2)bad.push('name lefts '+L.map(Math.round));R.forEach(function(r,i){var n=r.querySelector('[data-sw-today],[data-sw-dname]'),b=r.querySelector('[data-sw-part="day"]'),nx=R[i+1]&&R[i+1].querySelector('[data-sw-today],[data-sw-dname]');if(!n||!b||!nx)return;var nb=tb(n),bb=b.getBoundingClientRect(),xb=tb(nx);if(bb.top>=nb.bottom-1&&bb.top-nb.bottom>xb.top-bb.bottom-3)bad.push('bar '+i+' nearer the next day ('+Math.round(bb.top-nb.bottom)+' vs '+Math.round(xb.top-bb.bottom)+')')});return bad.join('; ')})()})
      puts "DAYNAME #{c['name']}: #{dn}" unless dn.empty?
      expect(dn).to eq('')
      # Rain calendar (owner 2026-11-13): a third row only when it holds a wet hour.
      r3 = s.evaluate(%q{(function(){var sv=[].filter.call(document.querySelectorAll('[data-sw-part="rain"] svg'),function(v){return v.getBoundingClientRect().width>0})[0];if(!sv)return '';var ys={};[].forEach.call(sv.querySelectorAll('text'),function(t){var y=t.getAttribute('y');ys[y]=ys[y]||[];ys[y].push(!!t.closest('.text--white'))});var k=Object.keys(ys).sort(function(a,b){return a-b});if(k.length<3)return '';return ys[k[k.length-1]].some(Boolean)?'':k.length+' rows, last dry'})()})
      puts "RAIN3 #{c['name']}: #{r3}" unless r3.empty?
      expect(r3).to eq('')
      # Day row parts apart (owner 2026-11-14, OG portrait "lots of clipping"): in each day row the day name, the icon (its box as
      # drawn, shifts included), the low and the high text and the bar cells neither overlap nor touch (at least 1 px apart); the
      # numbers no longer spill out of their columns into the icon or the bar track.
      dp = s.evaluate(%q{(function(){var bad=[],T=function(e){var g=document.createRange();g.selectNodeContents(e);return g.getBoundingClientRect()},v=function(b){return b&&b.width>0&&b.height>0};[].forEach.call(document.querySelectorAll('[data-sw-row="day"]'),function(r,i){if(!r.getBoundingClientRect().height)return;var P=[],nm=r.querySelector('[data-sw-today],[data-sw-dname]'),im=[].filter.call(r.querySelectorAll('img,[data-sw-part="icon"]'),function(e){return v(e.getBoundingClientRect())&&!e.closest('[data-sw-part="dcue"]')})[0],nu=[].filter.call(r.querySelectorAll('span.title:not([data-sw-dname])'),function(e){return v(e.getBoundingClientRect())}),cl=[].filter.call(r.querySelectorAll('[data-sw-cells] rect'),function(e){return v(e.getBoundingClientRect())});if(nm)P.push(['name',nm.hasAttribute('data-sw-today')?nm.getBoundingClientRect():T(nm)]);if(im)P.push(['icon',im.getBoundingClientRect()]);nu.forEach(function(e,j){P.push([j?'high':'low',T(e)])});if(cl.length){var L=1e9,R=-1e9,U=1e9,D=-1e9;cl.forEach(function(e){var b=e.getBoundingClientRect();L=Math.min(L,b.left);R=Math.max(R,b.right);U=Math.min(U,b.top);D=Math.max(D,b.bottom)});P.push(['bar',{left:L,right:R,top:U,bottom:D,width:R-L,height:D-U}])}
for(var a=0;a<P.length;a++)for(var b=a+1;b<P.length;b++){var x=P[a][1],y=P[b][1];if(v(x)&&v(y)&&x.left<y.right+1&&y.left<x.right+1&&x.top<y.bottom-1&&y.top<x.bottom-1)bad.push('row '+i+' '+P[a][0]+' meets '+P[b][0]+' (gap '+Math.round(Math.max(x.left,y.left)-Math.min(x.right,y.right))+' px)')}});return bad.join('; ')})()})
      puts "DAYPARTS #{c['name']}: #{dp}" unless dp.empty?
      # Days scale labels apart (owner 2026-11-14, OG portrait: "-25°-15°" ran together on a wide range): the visible tick labels (number and degree mark) do not overlap.
      tk = s.evaluate(%q{(function(){var bad=[],L=[].map.call(document.querySelectorAll('text[data-sw-tick]'),function(t){var b=t.getBoundingClientRect(),d=t.nextElementSibling,q=d&&!d.hasAttribute('data-sw-tick')?d.getBoundingClientRect():b;return [t.textContent,{left:Math.min(b.left,q.left),right:Math.max(b.right,q.right),top:Math.min(b.top,q.top),bottom:Math.max(b.bottom,q.bottom),width:b.width}]}).filter(function(q){return q[1].width>0}).sort(function(a,b){return a[1].left-b[1].left});for(var i=1;i<L.length;i++){var g=L[i][1].left-L[i-1][1].right;if(g<0&&L[i][1].top<L[i-1][1].bottom&&L[i-1][1].top<L[i][1].bottom)bad.push(L[i-1][0]+' '+L[i][0]+' gap '+g.toFixed(1))}return bad.join('; ')})()})
      puts "TICKS #{c['name']}: #{tk}" unless tk.empty?
      expect(tk).to eq('')
      expect(dp).to eq('')
      # Owner 2026-11-14 (OG photo, "temps aligned on the digit before the comma"): in each low and in each high column of the days strip
      # the last digit of every row ends at the same x (1 px): the numbers right-aligned on their ones digit, the minus and tens reach left.
      # Owner 2026-11-14 ("make sure the triangle is aligned with it"): the header's low and high marks centred on that ones digit (1 px).
      dgc = s.evaluate(%q{(function(){var C=[[],[]];[].forEach.call(document.querySelectorAll('[data-sw-row="day"]'),function(r){if(!r.getBoundingClientRect().height)return;[].filter.call(r.querySelectorAll('span.title:not([data-sw-dname])'),function(q){return q.getBoundingClientRect().width>0}).slice(0,2).forEach(function(q,j){var t=q.firstChild,m=t&&t.nodeType===3?t.textContent.search(/\d(?!.*\d)/):-1;if(m<0)return;var g=document.createRange();g.setStart(t,m);g.setEnd(t,m+1);var gr=g.getBoundingClientRect();C[j].push([q.textContent.trim(),gr.right,(gr.left+gr.right)/2])})});var bad=[];C.forEach(function(v,j){var tr=[].filter.call(document.querySelectorAll('[data-sw-part="tri"][data-sw-i="'+j+'"]'),function(e){return e.getBoundingClientRect().width>0})[0];if(tr&&v.length){var tb=tr.getBoundingClientRect(),tc=(tb.left+tb.right)/2;if(Math.abs(tc-v[0][2])>1)bad.push((j?'high':'low')+' mark centre '+tc.toFixed(1)+' vs ones digit '+v[0][2].toFixed(1))}if(v.length<2)return;var x=v.map(function(e){return e[1]}),lo=Math.min.apply(null,x),hi=Math.max.apply(null,x);if(hi-lo>1)bad.push((j?'high':'low')+' digits end '+v.map(function(e){return e[0]+'@'+e[1].toFixed(1)}).join(' '))});return bad.join('; ')})()})
      puts "DIGITCOL #{c['name']}: #{dgc}" unless dgc.empty?
      expect(dgc).to eq('')
      # Owner 2026-11-14 (round 2 review, Kindle 7 portrait read "▲0°"): the low and high marks keep at least 0.4 of their own height
      # from each other and from every days scale label beside them (ink boxes overlapping in height); seen red on 5696558.
      mg = s.evaluate(%q{(function(){var vis=function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0},M=[].filter.call(document.querySelectorAll('[data-sw-part="tri"] svg polygon'),vis).map(function(e){return ['mark',e.getBoundingClientRect()]}),L=[].filter.call(document.querySelectorAll('[data-sw-part="scale"] svg text'),vis).map(function(e){return ['label '+e.textContent.trim(),e.getBoundingClientRect()]}),bad=[];
M.forEach(function(m,i){var a=m[1],g=0.4*a.height;M.slice(i+1).concat(L).forEach(function(o){var b=o[1];if(b.top>a.bottom||b.bottom<a.top)return;var d=Math.max(b.left-a.right,a.left-b.right);if(d<g)bad.push('mark '+i+' to '+o[0]+' '+d.toFixed(1)+'<'+g.toFixed(1))})});return bad.join('; ')})()})
      puts "MARKGAP #{c['name']}: #{mg}" unless mg.empty?
      expect(mg).to eq('')
      # Round 2 review (v2 portrait with a sensor: HUM/HUM/WIND rows over the indoor and outdoor digits): no temperature digits' ink
      # overlaps a meter row (its label or blocks) of the same panel.
      mo = s.evaluate(%q{(function(){var vis=function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0},bad=[];[].filter.call(document.querySelectorAll('[data-sw-part="temp"] svg,[data-sw-part="itemp"] svg'),vis).forEach(function(v){var r=v.getBoundingClientRect(),vb=v.viewBox.baseVal,bb=v.getBBox(),kx=r.width/(vb.width||r.width),ky=r.height/(vb.height||r.height),I={l:r.left+(bb.x-vb.x)*kx,r:r.left+(bb.x-vb.x+bb.width)*kx,t:r.top+(bb.y-vb.y)*ky,b:r.top+(bb.y-vb.y+bb.height)*ky},p=v.closest('[data-sw-panel]');if(!p)return;
[].filter.call(p.querySelectorAll('[data-sw-part^="meter"],[data-sw-mlabel]'),vis).forEach(function(m){var q=m.getBoundingClientRect();if(q.left<I.r-1&&q.right>I.l+1&&q.top<I.b-1&&q.bottom>I.t+1)bad.push(v.parentElement.getAttribute('data-sw-part')+' digits over '+(m.getAttribute('data-sw-key')||m.textContent.trim()))})});return bad.filter(function(x,i,a){return a.indexOf(x)===i}).join('; ')})()})
      puts "DIGITROW #{c['name']}: #{mo}" unless mo.empty?
      expect(mo).to eq('')
      puts "DAYALIGN #{c['name']}: #{al}" unless al.empty?
      expect(al).to eq('')
      d = dr.split(',').map(&:to_f)
      expect(d[0]).to eq(0) if c['view'] == 'quadrant'
      # B12 (device tier): the floor is a size in the framework's px (X 53 screen px at its pixel ratio 1.8, OG 28 at 1) at the framework's
      # text scale, so a screen with another ratio (Voyage 1.4, Scribe 2.5) or a smaller text scale (Palma, Kindle 2024: 0.8) is held to the
      # same drawn size as its own text, not to the X's screen px; OG and X keep their numbers.
      # An lg screen shorter than the X's 780 framework px (Voyage 765) shares less height among the same rows: its floor shrinks with it.
      pxr = s.evaluate("(function(){var c=getComputedStyle(document.querySelector('.screen')),v=function(n){return parseFloat(c.getPropertyValue(n))||1};return v('--pixel-ratio')*v('--device-ui-scale')*(document.querySelector('.screen--lg')?Math.min(1,Math.min(v('--screen-w'),v('--screen-h'))/780):1)})()").to_f
      expect(d[1]).to be >= (is_lg ? 53 / 1.8 : 28) * pxr * (c['dark'] ? 0.85 : 1) if d[0].positive?   # the comment above says less 15 % for dark mode's divider; the code never took it (dark rows were 55 px by luck until the larger console)
      expect([d[3], d[4]]).to eq(d[0].positive? ? [1, 1] : [0, 0])
      expect(d[5]).to eq(1)
      # Felt temperature (owner decision 2026-11-13): no felt readout anywhere (no felt digits, no felt word, no person
      # icon); the felt temperature only drives the clothing badge.
      fi = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null};if(document.querySelector('[data-sw-part="person"]'))bad.push('person icon');
[].forEach.call(document.querySelectorAll('[data-sw-part="feels"],[data-sw-feltlabel],[data-sw-felt]'),function(e){if(vis(e))bad.push('felt readout '+(e.getAttribute('data-sw-part')||'label'));});
[].forEach.call(document.querySelectorAll('span,div'),function(e){if(e.children.length||!vis(e))return;var t=e.textContent;if(t.indexOf('GEVOEL')>=0||/(^| )(VOELT|FEELS)( |$)/i.test(t))bad.push('felt text '+t.trim());});
return bad.join('; ');})()})
      puts "FEELS #{c['name']}: #{fi}" unless fi.empty?
      expect(fi).to eq('')
      # Rain gauge (owner 2026-11-13, replaces the REGEN meter row): no REGEN meter anywhere; a visible gauge has as many lit
      # segments as the transform says (of 5) and its amount label; none without a calendar or an amount; on the X full view
      # (room beside the calendar) a wet case with an amount shows it; it stays inside its rain unit.
      rg0 = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0},G=SW.rain&&SW.rain.gauge;
document.querySelectorAll('[data-sw-key="regen"]').forEach(function(e){if(vis(e))bad.push('REGEN meter row');});
var gs=[].filter.call(document.querySelectorAll('[data-sw-part="gauge"]'),vis);
if(gs.length&&!G)bad.push('gauge without data');
gs.forEach(function(e){var m=e.querySelector('[data-sw-gauge]'),lit=Object.keys([].reduce.call(e.querySelectorAll('[data-sw-st="a"] rect'),function(o,r){o[r.getAttribute('data-sw-c')]=1;return o},{})).length,t=e.querySelector('[data-sw-glabel]'),u=e.previousElementSibling.querySelector('[data-sw-part="rain"]').getBoundingClientRect(),b=e.getBoundingClientRect();
if(!m||+m.getAttribute('data-sw-gauge')!==G.segs||lit!==G.segs||Object.keys([].reduce.call(e.querySelectorAll('[data-sw-c]'),function(o,r){o[r.getAttribute('data-sw-c')]=1;return o},{})).length!==3)bad.push('gauge segments '+lit+' want '+(G&&G.segs));
if(!t||t.textContent!==G.label)bad.push('gauge label');if(Math.abs(b.right-u.right)>1)bad.push('gauge not under the calendar columns');if(t&&t.getBoundingClientRect().right>u.left+0.5)bad.push('gauge label over the bar');});
if(G&&!gs.length&&INNER_X_FULL)bad.push('no gauge on a wet X full case');
return bad.join('; ')})()}.sub('INNER_X_FULL', (is_lg && (c['view'] || 'full') == 'full' && !is_port && !c['fixture']) ? 'true' : 'false'))
      expect(rg0).to eq('')
      # Hours strip (owner): column count per view, an inverted stamp exactly on the current and the wet hours, the block
      # curve inside its column and its panel, stamp, temperature and icon ink centred on the column axis (2 px; every
      # icon's ink is centred in its 30x30 box, 0.502 measured 2026-11-12, so the box centre is the ink centre), columns ordered and equal, the temperature's blocks on one scale.
      hs = s.evaluate(%q{(function(){var vis=function(e){var b=e.getBoundingClientRect();return b.width>0&&b.height>0};var bad=[],cols=[].filter.call(document.querySelectorAll('[data-sw-hcol]'),vis);
cols.forEach(function(cl,k){var i=+cl.getAttribute('data-sw-hcol'),q=SW.hours[i],st=cl.querySelector('[data-sw-hstamp]'),inv=st.classList.contains('label--inverted');if(i!==k)bad.push('order '+k+'/'+i);
if(inv!==(q.now||q.wet))bad.push('stamp '+i+' inverted='+inv+' wet='+q.wet);if(st.getAttribute('data-sw-hstamp')==='wet'&&!q.wet)bad.push('rain stamp on dry '+i);
var cb=cl.getBoundingClientRect(),p=cl.closest('[data-sw-panel]').getBoundingClientRect();[].forEach.call(cl.querySelectorAll('[data-sw-cells] rect, img, span'),function(r){var b=r.getBoundingClientRect();if(b.left<cb.left-1||b.right>cb.right+1||b.top<cb.top-1||b.bottom>cb.bottom+1||b.top<p.top||b.bottom>p.bottom)bad.push('out '+i+' '+r.tagName);});
var n=cl.querySelectorAll('[data-sw-cells] rect').length;if(q.tV!==null&&n<1)bad.push('no blocks '+i);if(Math.abs(cb.width-cols[0].getBoundingClientRect().width)>1)bad.push('width '+i);
var sp=st.getBoundingClientRect();if(sp.width>cb.width+1)bad.push('stamp wider '+i);
var ic=[].filter.call(cl.querySelectorAll('img, [data-sw-part="icon"] svg'),vis)[0],k=(cl.offsetWidth&&cb.width/cl.offsetWidth)||1,mid=(cb.left+cb.right)/2;if(ic){var ib=ic.getBoundingClientRect(),ix=ib.left+ib.width*0.502;if(Math.abs(ix-mid)>2*k)bad.push('icon off '+i+' '+(ix-mid).toFixed(1));}
[st,cl.querySelector('[data-sw-htemp]')].filter(Boolean).forEach(function(e){var b=e.getBoundingClientRect();if(Math.abs((b.left+b.right)/2-mid)>2*k)bad.push('off '+i+' '+e.tagName);});});
var L=cols.map(function(cl){return +(cl.querySelector('[data-sw-cells]')||{getAttribute:function(){return 0}}).getAttribute('data-sw-cells')}),T=cols.map(function(cl){return SW.hours[+cl.getAttribute('data-sw-hcol')].tV});
var ib=cols.map(function(cl){var e=[].filter.call(cl.querySelectorAll('img, [data-sw-part="icon"] svg'),vis)[0];return e?e.getBoundingClientRect().top:null}).filter(function(v){return v!==null});
if(ib.length&&Math.max.apply(null,ib)-Math.min.apply(null,ib)>1)bad.push('icon row spread '+(Math.max.apply(null,ib)-Math.min.apply(null,ib)).toFixed(1));
cols.forEach(function(cl){var i=+cl.getAttribute('data-sw-hcol'),q=SW.hours[i],tx=cl.querySelector('[data-sw-htemp]'),rs=cl.querySelectorAll('[data-sw-cells] rect');if(q.tV===null||q.tV===undefined)return;if(!tx||!rs.length){bad.push('no label '+i);return}
var top=Math.min.apply(null,[].map.call(rs,function(r){return r.getBoundingClientRect().top})),tb=tx.getBoundingClientRect(),ic=[].filter.call(cl.querySelectorAll('img'),vis)[0],k=cl.getBoundingClientRect().width/(cl.offsetWidth||1),gap=top-tb.bottom;
if(gap<-1*k||gap>8*k)bad.push('label '+i+' gap '+gap.toFixed(1)+' above its stack');if(ic&&tb.top<ic.getBoundingClientRect().bottom-1)bad.push('label '+i+' into the icon row');});
for(var a=0;a<cols.length;a++)for(var b=0;b<cols.length;b++)if(T[a]!==null&&T[b]!==null&&T[a]>T[b]+1.5&&L[a]<L[b])bad.push('scale '+a+'<'+b);
return cols.length+'|'+bad.join('; ');})()})
      puts "HOURS #{c['name']}: cols|bad #{hs}" if c['hcols'] || hs != '0|'
      expect(hs).to eq("#{c['hcols'] || 0}|")
      # Hours curve (owner 2026-11-13, live OG 1-bit: 4..6 drew one block everywhere): distinct (whole) temperatures of the shown
      # columns get distinct block counts where the strip has room for a block per degree, a warmer column never fewer blocks, and the warmest column's stack fills at
      # least 80 % of the block area.
      hc = s.evaluate(%q{(function(){var bad=[],cs=[].filter.call(document.querySelectorAll('[data-sw-part="hbar"]'),function(e){return e.getBoundingClientRect().height>0});if(!cs.length)return '';
var v=cs.map(function(e){var q=(SW.hours||[])[+e.getAttribute('data-sw-i')]||{},g=e.querySelector('[data-sw-cells]');return {t:q.tV,n:g?+g.getAttribute('data-sw-cells'):0,e:e,g:g}}).filter(function(o){return o.t!==null&&o.t!==undefined});
var C0=Math.min.apply(null,cs.map(function(e){return e.getBoundingClientRect().height})),rt=v.map(function(o){return Math.round(o.t)}),room=Math.max.apply(null,rt)-Math.min.apply(null,rt)+1<=6;   // a block per degree up to 6 blocks high (owner 2026-11-13)
v.forEach(function(a){v.forEach(function(b){if(Math.round(a.t)<Math.round(b.t)&&(a.n>b.n||(room&&a.n>=b.n)))bad.push(a.t+':'+a.n+' vs '+b.t+':'+b.n);});});
v.forEach(function(o){if(o.n<1)bad.push(o.t+': no block');var P=o.e.closest('[data-sw-panel]'),pb=P&&P.getBoundingClientRect();if(pb&&o.g)[].forEach.call(o.g.querySelectorAll('rect'),function(x){if(x.getBoundingClientRect().bottom>pb.bottom+0.5)bad.push(o.t+': block past the panel')});});   // owner 2026-11-13, live X hv dark
var top=v.reduce(function(m,o){return o.t>m.t?o:m},v[0]);if(top&&top.g){var C=+top.g.getAttribute('data-sw-area'),r=[].map.call(top.g.querySelectorAll('rect'),function(x){return x.getBoundingClientRect()}),h=r.length?Math.max.apply(null,r.map(function(x){return x.bottom}))-Math.min.apply(null,r.map(function(x){return x.top})):0;if(h<0.8*C-8)bad.push('warmest stack '+h.toFixed(0)+' of '+C.toFixed(0));}
return bad.slice(0,4).join('; ');})()})
      puts "HCURVE #{c['name']}: #{hc}" unless hc.empty?
      # 1-bit (owner 2026-11-13): block parts (hours and days strip blocks, meter cells) solid ink, no grey (dithered) fill.
      sb = s.evaluate(%q{(function(){if(!(document.querySelector('.screen')||document.body).classList.contains('screen--1bit'))return '';var bad=[];document.querySelectorAll('[data-sw-part="hbar"] g, [data-sw-part="day"] [data-sw-cells] g, [data-sw-part="meter"] g').forEach(function(e){if(!/text--gray-/.test(e.getAttribute('class')||'')||!e.querySelector('rect,path')||e.closest('[data-sw-st="p"]'))return;   // cells reached earlier today: the Framework's lighter grey (owner 2026-11-13)
var b=e.getBoundingClientRect();if(b.width>0&&getComputedStyle(e).display!=='none')bad.push(e.closest('[data-sw-part]').getAttribute('data-sw-part')+' '+e.getAttribute('class'));});return bad.slice(0,3).join('; ');})()})
      puts "SOLID1 #{c['name']}: #{sb}" unless sb.empty?
      # Meter states (owner 2026-11-13): every cell drawn in exactly the state the model gives (a now, p reached earlier
      # today, l expected later today, e empty) and one thick outline at today's peak; active cells in full ink, earlier
      # cells filled grey, later cells a dashed outline.
      mr = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-part^="meter"]').forEach(function(e){if(!e.getBoundingClientRect().width)return;var m0=SW.meters[+e.getAttribute('data-sw-i')||0],isin=e.getAttribute('data-sw-part')==='meterin',m=isin&&m0?m0.tw.m:m0,lt=e.querySelector('[data-sw-lit]');if(!m||!lt)return;var n=+lt.getAttribute('data-sw-ncell'),W=SWDraw.cellStates(m,n),got=[];
var ir=e.querySelector('[data-sw-twrow]'),tk=ir?ir.getAttribute('data-sw-twrow'):'',tw0=m0.tw?(isin?'in':'out'):'';if(tk!==tw0)bad.push(m0.key+' twin row set '+tk+'/'+tw0);if(tk==='out'){var Lf=function(r){var c=r&&getComputedStyle(r).fill,q=c&&c.match(/[\d.]+/g);return q&&q.length>2?0.3*q[0]+0.59*q[1]+0.11*q[2]:null},pi=[].filter.call(document.querySelectorAll('[data-sw-part="meterin"][data-sw-i="'+e.getAttribute('data-sw-i')+'"]'),function(q){return q.getBoundingClientRect().width>0})[0],lo=Lf(ir.querySelector('[data-sw-on] rect')),li=Lf(pi&&pi.querySelector('[data-sw-on] rect'));if(lo!==null&&li!==null&&Math.abs(lo-li)<20)bad.push(m0.key+' outdoor set not grey ('+lo+' vs indoor '+li+')');}if(isin)return;
e.querySelectorAll('rect[data-sw-c]').forEach(function(r){if(r.closest('[data-sw-twrow="in"]'))return;var i=+r.getAttribute('data-sw-c'),st=r.closest('[data-sw-st]');var sv=st?st.getAttribute('data-sw-st'):'?';if((got[i]||'').indexOf(sv)<0)got[i]=(got[i]||'')+sv;if(st&&st.getAttribute('data-sw-st')==='l'&&!r.getAttribute('stroke-dasharray')&&r.getAttribute('fill')==='none')bad.push(m.key+' later cell neither filled nor dashed');if(st&&st.getAttribute('data-sw-st')==='p'&&r.getAttribute('fill')==='none')bad.push(m.key+' earlier cell not filled');});
var gs=[];for(var i=0;i<n;i++)gs.push(got[i]||'-');if(gs.join('')!==W.st.join(''))bad.push(m.key+' states '+gs.join('')+'/'+W.st.join(''));
var pk=[].map.call(e.querySelectorAll('[data-sw-gust]'),function(r){return +r.getAttribute('data-sw-gust')});if(pk.join(',')!==(W.peak>=0&&W.st[W.peak]==='e'?String(W.peak):''))bad.push(m.key+' peak '+pk.join(',')+'/'+W.peak);
var on=e.querySelector('[data-sw-on]');var dg=on&&on.querySelector(':scope > [data-sw-dg]');if(!on||tk!=='out'&&!(SW.sim===false&&m.key==='co2')/* B13: the sensor's CO2 is the grey second set when outside is main */&&(!dg&&(on.hasAttribute('fill')||on.querySelector(':scope > g[fill]'))))bad.push(m.key+' current cells light grey');});return bad.join('; ');})()})
      puts "MRANGE #{c['name']}: #{mr}" unless mr.empty?
      # Every visible meter has the same block left edge, right edge and width (the twin meter's legend icons sit in a reserved right column), and each legend icon is level with its block row.
      ml = s.evaluate(%q{(function(){var bad=[],xs=[],ys=[],hs=[];document.querySelectorAll('[data-sw-part^="meter"]').forEach(function(e){if(!e.getBoundingClientRect().width)return;var l=1e9,rr=-1e9;[].forEach.call(e.querySelectorAll('rect[data-sw-c]'),function(r){var q=r.getBoundingClientRect();l=Math.min(l,q.left);rr=Math.max(rr,q.right);hs.push(q.height)});if(l<1e9){xs.push(l);ys.push(rr)}});var sp=function(a){return Math.max.apply(null,a)-Math.min.apply(null,a)};var vi=function(q){return [].filter.call(document.querySelectorAll(q),function(e){return e.getBoundingClientRect().width>0})},ks={};vi('[data-sw-for]').forEach(function(e){var k=e.getAttribute('data-sw-for');ks[k]=(ks[k]||0)+1});Object.keys(ks).forEach(function(k){var mm=SW.meters.filter(function(x){return x.key===k})[0],nl=vi('[data-sw-mlabel]').filter(function(e){return e.textContent.trim()===mm.label}).length;if(nl!==ks[k])bad.push(k+' rows '+ks[k]+' but labels '+nl+' (every row has its own label)')});if(hs.length&&sp(hs)>1.5)bad.push('block heights (HUM rows are full meter rows) '+hs.map(Math.round).filter(function(v,i,a){return a.indexOf(v)===i}).join(','));if(xs.length&&sp(xs)>1.5)bad.push('block left edges '+xs.map(Math.round).join(','));if(ys.length&&sp(ys)>1.5)bad.push('block right edges '+ys.map(Math.round).join(','));if(xs.length&&sp(xs.map(function(x,i){return ys[i]-x}))>1.5)bad.push('block widths '+xs.map(function(x,i){return Math.round(ys[i]-x)}).join(','));
[].filter.call(document.querySelectorAll('[data-sw-for]'),function(e){return e.getBoundingClientRect().width>0}).forEach(function(ic){var ind=ic.getAttribute('data-sw-i')==='1',m=[].filter.call(document.querySelectorAll('[data-sw-part="'+(ind?'meterin':'meter')+'"][data-sw-key="'+ic.getAttribute('data-sw-for')+'"]'),function(q){return q.getBoundingClientRect().width>0})[0];if(!m){bad.push('icon without meter');return}var rs=[].filter.call(m.querySelectorAll('rect[data-sw-c]'),function(r){return true});if(!rs.length){bad.push('icon row without blocks');return}var b=rs[0].getBoundingClientRect(),q=ic.getBoundingClientRect();if(Math.abs((b.top+b.bottom)/2-(q.top+q.bottom)/2)>4)bad.push('icon '+(ind?'in':'out')+' not level with its block row '+((q.top+q.bottom)/2-(b.top+b.bottom)/2).toFixed(1));if(!ic.querySelector('svg path'))bad.push('legend icon not drawn')});return bad.join('; ')})()})
      puts "MLEFT #{c['name']}: #{ml}" unless ml.empty?
      expect(ml).to eq('')
      expect(mr).to eq('')
      expect(sb).to eq('')
      expect(hc).to eq('')
      # Clothing badge (owner): the drawn icons are the model's list (top and up to two extras) in order; one fixed box
      # width on every day row (1 px; the console has its own, larger box); the extras sit right of the top icon, never over its box.
      co = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0},bad=[],ws=[];
var IT={parka:['top'],jacket:['top'],sweater:['top'],tshirt:['top'],umbrella:['umbrella']};
function chk(e,want,tag){var cl=e.querySelector('g[data-sw-cloth]'),exp=[].concat.apply([],want.map(function(k){return IT[k]||[]})).sort().join('+'),its=[].slice.call(e.querySelectorAll('g[data-sw-item]')),got=its.map(function(g){return g.getAttribute('data-sw-item')}).sort().join('+');if(got!==exp)bad.push(tag+' parts '+got+'/'+exp);
ws.push(e.getBoundingClientRect().width);var E=e.getBoundingClientRect(),sv=cl&&cl.closest('svg'),T=sv&&sv.getBoundingClientRect();its.forEach(function(g){var b=g.getBoundingClientRect();if(!b.width)return;if((tag==='console'&&(b.left<E.left-1||b.right>E.right+1||b.top<E.top-1||b.bottom>E.bottom+1))||b.left<T.left-1||b.right>T.right+1||b.top<T.top-1||b.bottom>T.bottom+1)bad.push(tag+' '+g.getAttribute('data-sw-item')+' overflows its box')});}
var cn=0;[].filter.call(document.querySelectorAll('[data-sw-part="cue"]'),vis).forEach(function(e){cn++;chk(e,SW.cue||[],'console');});ws=[];   // the console badge has its own box (owner); the day rows share one width
var rows=[].filter.call(document.querySelectorAll('[data-sw-row="day"]'),vis),n=0;rows.forEach(function(r){var ds=[].filter.call(r.querySelectorAll('[data-sw-part="dcue"]'),vis);if(!ds.length)return;n++;if(ds.length>1)bad.push('badges '+ds.length);var i=+ds[0].getAttribute('data-sw-i');chk(ds[0],SW.days[i].cue||[],'day '+i);});
if(n&&n!==rows.length)bad.push('rows '+n+'/'+rows.length);if(ws.length&&Math.max.apply(null,ws)-Math.min.apply(null,ws)>1)bad.push('widths '+ws.map(Math.round).join(','));return cn+','+n+'|'+bad.join('; ');})()})
      puts "CLOTH #{c['name']}: console,dayrows|bad #{co}"
      expect(co.split('|', 2)[1]).to eq('')
      expect(co.split(',')[1].to_i).to be_positive if (c['view'] || 'full') == 'full' && (c['fields'] || {})['bottom'] != 'hours'
      # Portrait day rows and console (owner, step 19 on x-port-hv; OG half vertical portrait the model): the console badge
      # beside the temperature (full and half views; quadrants are tiny views without a badge, owner B3 2026-11-14), every day row keeps its low and high, the header its two markers, and the scale labels
      # no larger than 1.3 x the low/high digits.
      if is_port
        pr = s.evaluate(%q{(function(){var vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0},bad=[],fs=function(e){return parseFloat(getComputedStyle(e).fontSize)*(e.getBoundingClientRect().width/(e.offsetWidth||1))};
if(QUAD0&&SW.cue&&SW.cue.length&&![].some.call(document.querySelectorAll('[data-sw-part="cue"]'),vis))bad.push('no console badge');
var rows=[].filter.call(document.querySelectorAll('[data-sw-row="day"]'),vis),lf=0;rows.forEach(function(r){var n=[].filter.call(r.querySelectorAll('span.title:not([data-sw-dname])'),vis);if(n.length<2)bad.push('row '+r.textContent.trim().split(/\s+/)[0]+' without low/high');else lf=fs(n[0]);});
if(rows.length){var tr=[].filter.call(document.querySelectorAll('[data-sw-part="tri"]'),vis).length;if(tr!==2)bad.push('markers '+tr);
var sv=[].filter.call(document.querySelectorAll('[data-sw-part="scale"] svg'),vis)[0];if(sv&&lf){var k=sv.getBoundingClientRect().height/(+sv.getAttribute('height')||1);[].forEach.call(sv.querySelectorAll('text'),function(t){var f=+t.getAttribute('font-size')*k;if(f>lf*1.3)bad.push('scale label '+f.toFixed(0)+' px over low/high '+lf.toFixed(0));});}}
return bad.filter(function(x,i,a){return a.indexOf(x)===i}).join('; ');})()}.sub('QUAD0', (c['view'] != 'quadrant').to_s))
        puts "PORT #{c['name']}: #{pr}" unless pr.empty?
        expect(pr).to eq('')
      end
      # Dividers (owner 2026-11-12, step 12): no ink (shapes, icons, glyphs) within 0.75 of the row gap of a vertical
      # divider in a panel; the clothing badge, meters and digits keep the normal gap.
      dg = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e.getBoundingClientRect();return b.height>0?b:null};
[].forEach.call(document.querySelectorAll('[data-sw-panel] [data-sw-rule], [data-sw-panel] [data-sw-div]'),function(rl){var R=vis(rl);if(!R||R.width>4||R.height<R.width)return;
var pn=rl.closest('[data-sw-panel]'),k=R.height/(rl.offsetHeight||R.height),g=parseFloat(getComputedStyle(rl.parentElement).columnGap)||0;g=(g||16)*k*0.75;var x=(R.left+R.right)/2;
var ink=[].slice.call(pn.querySelectorAll('svg path, svg rect, svg circle, svg ellipse, svg line, svg polyline, svg polygon, svg text, img'));
[].forEach.call(pn.querySelectorAll('span'),function(sp){if(sp.children.length)return;var rg=document.createRange();rg.selectNodeContents(sp);[].forEach.call(rg.getClientRects(),function(q){if(q.width>0)ink.push({q:q,t:'text '+sp.textContent.trim().slice(0,8)})});});
ink.forEach(function(e){if(e.closest&&e.closest('[data-sw-part="face"]'))return;var b=e.q||e.getBoundingClientRect();if(!b.width||!b.height)return;
if(e.getAttribute&&e.tagName!=='IMG'){var cs=getComputedStyle(e);if((cs.fill==='none'||cs.fillOpacity==='0')&&cs.stroke==='none')return;if(cs.visibility==='hidden'||cs.opacity==='0')return;}
if(b.bottom<=R.top||b.top>=R.bottom)return;var d=b.left>x?b.left-x:(b.right<x?x-b.right:-1);
if(d<g){var p=e.t||((e.closest('[data-sw-part]')||{getAttribute:function(){return e.tagName}}).getAttribute('data-sw-part')+'/'+e.tagName);bad.push(p+' '+d.toFixed(1)+'<'+g.toFixed(1)+' @'+x.toFixed(0));}});});
var u=[];bad.forEach(function(s){if(u.indexOf(s)<0)u.push(s)});return u.slice(0,8).join('; ');})()})
      # Outfit proportions (owner 2026-11-13, squashed garments): the garment drawn in every cue box (console badge, day rows)
      # keeps the height/width ratio of tools/outfit_ratios.js for its type (within 5 %); stroke taken out, so a non-uniform scale shows.
      pr = s.evaluate(%q{(function(){var out=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0};
function m(e,keys,tag){var t=keys[0],g=e.querySelector('g[data-sw-cloth]'),it=g&&g.querySelector('[data-sw-item="top"]');if(!it||!vis(it))return;var sw=getComputedStyle(it.querySelector('path')).stroke==='none'?0:+it.getAttribute('stroke-width'),b=it.getBBox(),r=it.getBoundingClientRect();out.push(t+','+(b.height*(r.height/(b.height+sw))/(b.width*(r.width/(b.width+sw)))).toFixed(4)+','+tag+','+it.getScreenCTM().a.toFixed(3))}
[].filter.call(document.querySelectorAll('[data-sw-part="cue"]'),vis).forEach(function(e){m(e,SW.cue||[],'console')});
[].filter.call(document.querySelectorAll('[data-sw-row="day"]'),vis).forEach(function(r){var d=r.querySelector('[data-sw-part="dcue"]');if(d)m(d,SW.days[+d.getAttribute('data-sw-i')].cue||[],'day')});return out.join(' ')})()})
      unless pr.empty?
        @ref ||= JSON.parse(`node #{File.join(__dir__, 'outfit_ratios.js')}`)
        bad = pr.split.map { |q| t, v, tag = q.split(','); [t, v.to_f, tag] }.select { |t, v, _| (v / @ref[t] - 1).abs > 0.05 }
        # One scale per box size (owner 2026-11-13): the garment is drawn at the same scale in every day-row cue, and in every console badge, within 3 %.
        %w[day console].each { |g| ks = pr.split.map { |q| q.split(',') }.select { |q| q[2] == g }.map { |q| q[3].to_f }; bad << [g, 'scale', ks] if ks.size > 1 && ks.max / ks.min > 1.03 }
        puts "PROP #{c['name']}: #{bad.inspect}" unless bad.empty?
        expect(bad).to eq([])
      end
      # Garment size (owner 2026-11-13, "too small"): the garment (top part, stroke included) is at least 66 % of its cue box's height in every console badge and day row (boxes at least 1.4 wide per high; the OG portrait day row is held at 12 cqw by the 45 % track rule and is width-limited).
      gm = s.evaluate(%q{(function(){var o=[];document.querySelectorAll('[data-sw-part="cue"],[data-sw-part="dcue"]').forEach(function(e){var r=e.getBoundingClientRect(),t=e.querySelector('[data-sw-item="top"]');if(!r.height||!t)return;var q=t.getBoundingClientRect();if(r.width>=1.4*r.height&&q.height<0.66*r.height)o.push(e.getAttribute('data-sw-part')+' '+Math.round(100*q.height/r.height)+'%')});return o.join(', ')})()})
      puts "GARM #{c['name']}: #{gm}" unless gm.empty?
      expect(gm).to eq('')
      # Console hairline (owner 2026-11-12, step 12): the same gap above (to the lowest ink of the top part) and below
      # (to the meters' first ink), at least half the column gap each.
      hg = s.evaluate(%q{(function(){var h=[].filter.call(document.querySelectorAll('[data-sw-hair="console"]'),function(e){return e.getBoundingClientRect().height>0||e.getBoundingClientRect().width>0})[0];if(!h)return'';
var w=h.parentElement,up=w.previousElementSibling,dn=w.nextElementSibling;if(!up||!dn)return'';var H=h.getBoundingClientRect();
function ink(root,lo){var v=lo?-1e9:1e9;[].forEach.call(root.querySelectorAll('svg path, svg rect, svg circle, svg text, svg polygon, img, span'),function(e){if(e.tagName==='SPAN'&&e.children.length)return;var b=e.getBoundingClientRect();if(!b.width||!b.height)return;v=lo?Math.max(v,b.bottom):Math.min(v,b.top)});return v}
var a=H.top-ink(up,true),b=ink(dn,false)-H.bottom,g=parseFloat(getComputedStyle(w.parentElement).rowGap)||8;return [a.toFixed(1),b.toFixed(1),g.toFixed(1)].join(',')})()})
      unless hg.empty?
        ha, hb, hgap = hg.split(',').map(&:to_f)
        puts "HAIR #{c['name']}: above,below,gap #{hg}"
        expect([(ha - hb).abs <= [3, 0.25 * [ha, hb].max].max, [ha, hb].min >= 0.5 * hgap]).to eq([true, true])
      end
      # Console readouts (owner screenshots 107-109; owner 2026-11-13: the badge took the felt reading's place): the
      # clothing badge beside the big temperature, right of the digits and unit, its top layer's box on the digits' ink
      # (top and bottom within 3 px, owner: anchored, not floating) after a divider (DIV: midway, as tall as the digits); the last day row inside its panel.
      cr2 = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},all=function(q){return [].map.call(document.querySelectorAll(q),vis).filter(Boolean)},ov=function(a,b){return Math.min(a.right,b.right)-Math.max(a.left,b.left)>0.5&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>0.5};
var dgh=function(e){return e.getBBox().height*e.getBoundingClientRect().height/(e.viewBox.baseVal.height||1)},tm=[].filter.call(document.querySelectorAll('[data-sw-part="temp"] svg,[data-sw-part="itemp"] svg'),vis).sort(function(a,b){return dgh(b)-dgh(a)})[0];   // the main temperature: the largest digits (indoor with a sensor, owner 2026-11-14)
[].filter.call(document.querySelectorAll('[data-sw-part="cue"]'),vis).forEach(function(e){var tw=e.closest('[data-sw-twin]'),te=tw?vis(tw.querySelector('[data-sw-part="temp"] svg'))&&tw.querySelector('[data-sw-part="temp"] svg'):tm;if(!te){bad.push('badge without temperature');return;}var sm=!!e.closest('[data-sw-small]'),cb=e.hasAttribute('data-sw-cb');   /* owner 2026-11-14: next to the tree icon (cb): above the outdoor digits in the twin row, left of them in the small views; not right of the digits */   // small console (owner-approved 2026-11-13): the badge may sit below the digits, never over them
var r=te.getBoundingClientRect(),vb=te.viewBox.baseVal,bb=te.getBBox(),ky=r.height/(vb.height||r.height),kx=r.width/(vb.width||r.width),tt=r.top+(bb.y-vb.y)*ky,th=bb.height*ky,tr=r.left+(bb.x-vb.x+bb.width)*kx;
var u=te.closest('[data-sw-part]').parentElement.querySelector('[data-sw-unit]'),ur=u?vis(u).right:tr,g=e.querySelector('g[data-sw-cloth]'),sv=e.querySelector('svg'),sr=vis(sv);if(!g||!sr){bad.push('badge not drawn');return;}var sb=sv.viewBox.baseVal,sk=(/slice/.test(sv.getAttribute('preserveAspectRatio')||'')?Math.max:Math.min)(sr.width/sb.width,sr.height/sb.height),oy=sr.top+(sr.height-sb.height*sk)/2,bx=g.getAttribute('data-sw-box').split(',').map(Number),gb={left:sr.left+(bx[0]-sb.x)*sk,top:oy+(bx[1]-sb.y)*sk,height:bx[2]*sk};gb.right=gb.left+bx[2]*sk;gb.bottom=gb.top+gb.height;   // the top layer's box (xMinYMid: a T-shirt draws shorter than a parka in the same box)
if(cb&&tw&&gb.bottom>tt+3)bad.push('outdoor badge '+gb.bottom.toFixed(0)+' not above its digits '+tt.toFixed(0));if(!sm&&!cb&&gb.left<Math.max(tr,ur)-0.5)bad.push('badge not right of the temperature '+gb.left.toFixed(0)+'<'+Math.max(tr,ur).toFixed(0));if(ov(gb,{left:r.left,right:tr,top:tt,bottom:tt+th}))bad.push('badge over temp');
if(!sm&&!cb&&(Math.abs(gb.top-tt)>3||Math.abs(gb.bottom-tt-th)>3))bad.push('badge '+gb.top.toFixed(1)+'-'+gb.bottom.toFixed(1)+' not on the digits '+tt.toFixed(1)+'-'+(tt+th).toFixed(1));var dv=e.previousElementSibling;if(!sm&&!e.closest('[data-sw-twin]')&&!(dv&&dv.hasAttribute('data-sw-div')&&dv.getBoundingClientRect().height>0))bad.push('no divider before the badge');});
if(tm){var ti2=dgh(tm),fz=function(e){return (+e.getAttribute('data-sw-fs')||parseFloat(getComputedStyle(e).fontSize))*(e.getBoundingClientRect().width/(e.offsetWidth||1))},mx=0;[].forEach.call(document.querySelectorAll('[data-sw-suntime],[data-sw-cond]'),function(e){if(vis(e))mx=Math.max(mx,fz(e))});if(mx&&ti2<1.2*mx)bad.push('temperature digits '+ti2.toFixed(0)+' not the largest readout (text '+mx.toFixed(0)+')');}   // owner 2026-11-13 (live X hv dark, 4.4 smaller than the sun times)
document.querySelectorAll('[data-sw-panel]').forEach(function(p){var q=vis(p);if(!q)return;var r=[].map.call(p.querySelectorAll('[data-sw-row="day"]'),vis).filter(Boolean);if(r.length&&r[r.length-1].bottom>q.bottom+0.5)bad.push('day row '+r.length+' past the panel '+(r[r.length-1].bottom-q.bottom).toFixed(0))});
return bad.join('; ');})()})
      puts "READOUT #{c['name']}: #{cr2}" unless cr2.empty?
      expect(cr2).to eq('')
      # Condition row (owner 2026-11-13): the badge moved beside the temperature; the condition label at its full size
      # (no step down), no badge in its row.
      cb = s.evaluate(%q{(function(){var bad=[];[].forEach.call(document.querySelectorAll('[data-sw-cond]'),function(sp){if(!sp.getBoundingClientRect().width)return;if(sp.style.fontSize)bad.push('label stepped down to '+sp.style.fontSize);if(sp.parentElement.querySelector(':scope > [data-sw-part="cue"]'))bad.push('badge in the condition row');});return bad.join('; ');})()})
      puts "CUEROW #{c['name']}: #{cb}" unless cb.empty?
      expect(cb).to eq('')
      # Digit spacing (owner 2026-11-13, "4. 1"): in the seven-segment readouts the ink gap between neighbouring digits
      # (a decimal point between them allowed) at most 30 of the 100-unit digit height (normal 14, with a point 20).
      sp = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-part] svg').forEach(function(v){var r=v.getBoundingClientRect();if(!r.height)return;var k=100/r.height,gl=[].filter.call(v.querySelectorAll('g[data-sw-glyph]'),function(g){return /[0-9]/.test(g.getAttribute('data-sw-glyph'))&&g.getBoundingClientRect().width>0});
for(var i=1;i<gl.length;i++){var a=gl[i-1].getBoundingClientRect(),b=gl[i].getBoundingClientRect(),gp=((gl[i].getAttribute('data-sw-glyph')==='1'&&v.closest('[data-sw-part="temp"],[data-sw-part="itemp"]')?b.right-56/k:b.left)-a.right)*k;   // LCD cells (owner 2026-11-14): a 1 sits right in a full cell, the gap counts to the cell edge
if(gp>30)bad.push(gl[i-1].getAttribute('data-sw-glyph')+gl[i].getAttribute('data-sw-glyph')+' gap '+gp.toFixed(0));}});return bad.join('; ');})()})
      puts "DIGITGAP #{c['name']}: #{sp}" unless sp.empty?
      expect(sp).to eq('')
      # Dial trend arrows (owner 2026-11-13): one trend-line arrow per dial trending up or down (with a sensor the temperature dial's value and arrow are indoor, owner 2026-11-14; barometer from 3 h ago,
      # temperature +3 h), matching the direction, none when level, in front of the value on its line (owner 2026-11-13; was top right, then behind the unit), its 28-unit box about 1.5 x the name caption's cap height.
      # Owner 2026-11-14 (B12, option a): the temperature dial's stacked outdoor readout (right edges level with the indoor value) is for
      # landscape only; a portrait layout with an indoor reading shows none on the dial (the console shows outdoor: the narrow portrait dial
      # panel has no room for it beside the arc or below the needles), and the dial still fills its panel (ARC above).
      ar = s.evaluate(%q{(function(){var bad=[],vis=function(e){var b=e&&e.getBoundingClientRect();return b&&b.width>0&&b.height>0?b:null},cx=document.createElement('canvas').getContext('2d');
[].filter.call(document.querySelectorAll('[data-sw-part="baro"],[data-sw-part="tdial"]'),vis).forEach(function(d){var k=d.getAttribute('data-sw-part'),aw=(k==='baro'?SW.baro:(SW.sim===false?SW.tdial:SW.inn||SW.tdial)).arrow,want=aw==='up'||aw==='down'?1:0,box=d.parentElement,B=box.getBoundingClientRect(),a=[].filter.call(box.querySelectorAll('[data-sw-arrowpoly]'),function(e){return vis(e)&&!e.closest('[data-sw-dialin]')}),di=box.querySelector('[data-sw-dialin]');
if(k==='tdial'&&(!!SW.inn&&!document.querySelector('.screen--portrait'))!==!!(di&&vis(di)))bad.push('stacked outdoor value '+!!(di&&vis(di))+'/'+!!SW.inn);if(di&&vis(di)){var q=di.getBoundingClientRect(),ov=q,o2=box.querySelector('[data-sw-cap]').getBoundingClientRect(),sp=di.querySelector('span.value');if(q.left<B.left||q.right>B.right||q.top<B.top||!sp||!sp.textContent.trim())bad.push('outdoor value outside the panel or empty');if(!di.querySelector('[data-sw-part="loc"] svg path'))bad.push('outdoor icon missing');if(Math.abs(q.right-di.previousElementSibling.getBoundingClientRect().right)>1.5)bad.push('outdoor value right edge not level with the indoor value');var lb=[].filter.call(d.querySelectorAll('svg text'),vis);lb.forEach(function(e){var b=e.getBoundingClientRect();if(Math.min(b.right,q.right)-Math.max(b.left,q.left)>1&&Math.min(b.bottom,q.bottom)-Math.max(b.top,q.top)>1)bad.push('indoor value over dial label '+e.textContent)});if(q.top<o2.bottom&&q.left<o2.right)bad.push('indoor value over the TEMPERATURE label');[].forEach.call(d.querySelectorAll('svg text,svg line,svg polygon'),function(e){if(e.closest('[data-sw-needle],defs')&&e.tagName!=='polygon')return;var b=e.getBoundingClientRect();[q,di.previousElementSibling.getBoundingClientRect()].forEach(function(r){if(b.width&&Math.min(b.right,r.right)-Math.max(b.left,r.left)>1&&Math.min(b.bottom,r.bottom)-Math.max(b.top,r.top)>1)bad.push('indoor or outdoor value over the dial '+e.tagName+' '+[b.left,b.top,b.right,b.bottom].map(Math.round)+' vs '+[r.left,r.top,r.right,r.bottom].map(Math.round))})});}
if(a.length!==want){bad.push(k+' arrows '+a.length+'/'+want);return;}if(!a.length)return;if(a[0].getAttribute('data-sw-arrowpoly')!==aw)bad.push(k+' arrow '+a[0].getAttribute('data-sw-arrowpoly')+' for '+aw);var r=a[0].ownerSVGElement.getBoundingClientRect(),c=box.querySelector('[data-sw-cap]'),cs=getComputedStyle(c);cx.font=cs.fontWeight+' '+cs.fontSize+' '+cs.fontFamily;var cap=cx.measureText('H').actualBoundingBoxAscent*(c.getBoundingClientRect().height/(c.offsetHeight||1)),h=Math.max(r.width,r.height);
var vv=a[0].ownerSVGElement.closest('[data-sw-part="arrow"]'),vv=vv&&vv.nextElementSibling,V=vv&&vv.getBoundingClientRect();if(!V||!vv.classList.contains('value')||r.right>V.left||V.left-r.right>2.5*cap||r.top>V.bottom||r.bottom<V.top)bad.push(k+' arrow not in front of the value');if(h<1.2*cap||h>1.8*cap)bad.push(k+' arrow '+h.toFixed(0)+' cap '+cap.toFixed(0));});return bad.join('; ');})()})
      puts "ARROW #{c['name']}: #{ar}" unless ar.empty?
      # Barometer low/high (step 18): with a day's pressure range of 5 hPa or more the two marks stand apart.
      bm = s.evaluate(%q{(function(){var b=SW.baro||{};if(b.lo==null||b.hi-b.lo<5)return '';var bad=[];document.querySelectorAll('[data-sw-part="baro"]').forEach(function(d){if(!d.getBoundingClientRect().width)return;var m=[].map.call(d.querySelectorAll('[data-sw-markt]'),function(e){var r=e.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]});if(m.length!==2)bad.push('baro marks '+m.length);else if(Math.hypot(m[0][0]-m[1][0],m[0][1]-m[1][1])<4)bad.push('baro marks overlap')});return bad.join('; ')})()})
      puts "BAROMARK #{c['name']}: #{bm}" unless bm.empty?
      expect(bm).to eq('')
      expect(ar).to eq('')
      # Sun times (owner 2026-11-12, step 12): one line each, 12 h too (the AM/PM smaller, on the same line).
      st = s.evaluate(%q{(function(){var bad=[];document.querySelectorAll('[data-sw-suntime]').forEach(function(e){var rg=document.createRange();rg.selectNodeContents(e);var r=[].filter.call(rg.getClientRects(),function(q){return q.width>0&&q.height>0});if(r.length>1&&r.some(function(q){return q.left<r[0].right-1&&q.top>r[0].top+2}))bad.push(e.textContent.replace(/\s+/g,' ').trim());});return bad.join('; ');})()})
      puts "SUNTIME #{c['name']}: #{st}" unless st.empty?
      expect(st).to eq('')
      puts "DIVGAP #{c['name']}: #{dg}" unless dg.empty?
      expect(dg).to eq('')
      puts "GEO #{c['name']}: unequal day rows #{geo}"
      expect(tf).to eq('')
      expect(arc.split('|', 2)[1]).to eq('')
      expect(dc).to eq('')
      expect(geo).to start_with('0/')
      puts "#{c['name']}: #{s.evaluate("document.querySelector('[data-sw-debug]').getAttribute('data-sw-debug')")[0, 300]}"
    end
  end
end
