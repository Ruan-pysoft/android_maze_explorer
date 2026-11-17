package android_maze_explorer

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import "core:time"

THREEDEE_GRAPHICS_SCALE :: 8

State :: struct {
	app_has_been_init: bool,
	should_quit: bool,
	last_frame_time_nanos: i64,

	ctx: runtime.Context,

	last_touch_pos: [2]int,

	window_size: [2]int,
	window_size_changed: bool,

	canvas: Canvas,
	canvas3d: Canvas3D,
}

RENDER_ASAP :: #config(RENDER_ASAP, true)

main :: proc() {
	context.logger = log.create_console_logger(ident="android-maze-explorer")

	state: State
	state.ctx = context

	app := glue.app()
	app.userData = &state
	app.onAppCmd = on_app_cmd
	app.onInputEvent = auto_cast on_input_event

	when RENDER_ASAP {
		for app.destroyRequested == 0 && !state.should_quit && !state.app_has_been_init {
			source: ^glue.android_poll_source
			if android.ALooper_pollOnce(
				-1,
				nil,
				nil,
				(^rawptr)(&source),
			) >= 0 && source != nil {
				source.process(app, source)
			}
		}
		for app.destroyRequested == 0 && !state.should_quit {
			for app.destroyRequested == 0 && !state.should_quit {
				source: ^glue.android_poll_source
				poll_res := android.ALooper_pollOnce(
					0,
					nil,
					nil,
					(^rawptr)(&source),
				)
				if poll_res >= 0 && source != nil {
					source.process(app, source)
				} else if poll_res < 0 do break
			}

			time_nsec := time.tick_now()._nsec
			dt_nsec := time_nsec - state.last_frame_time_nanos
			state.last_frame_time_nanos = time_nsec

			process(app, &state, dt_nsec)
		}
	} else {
		for app.destroyRequested == 0 && !state.should_quit {
			source: ^glue.android_poll_source
			if android.ALooper_pollOnce(
				-1,
				nil,
				nil,
				(^rawptr)(&source),
			) >= 0 && source != nil {
				source.process(app, source)
			}
		}
	}
}

frame_cb :: proc"c"(frame_time_nanos: i64, data: rawptr) {
	app := cast(^glue.android_app) data
	state := cast(^State) app.userData
	context = state.ctx
	defer android.ALooper_wake(app.looper)
	defer android.AChoreographer_postFrameCallback64(
		android.AChoreographer_getInstance(),
		frame_cb,
		app,
	)
	frame_length_nanos := frame_time_nanos - state.last_frame_time_nanos
	state.last_frame_time_nanos = frame_time_nanos

	process(app, state, frame_length_nanos)
}

process :: proc(app: ^glue.android_app, state: ^State, dt_nsec: i64) {
	fps := 1_000_000_000 / dt_nsec

	log.info("In frame callback! FPS:", fps)

	draw(app, state)
}

on_app_cmd :: proc(app: ^glue.android_app, cmd: i32) {
	state := (^State)(app.userData)
	switch cmd {
	case glue.APP_CMD_INIT_WINDOW, glue.APP_CMD_WINDOW_RESIZED, glue.APP_CMD_WINDOW_REDRAW_NEEDED:
		w, h := int(android.ANativeWindow_getWidth(app.window)), int(android.ANativeWindow_getHeight(app.window))
		log.debug("Window size changed to:", w, h)
		if state.window_size != {w, h} {
			state.window_size = {w, h}
			state.window_size_changed = true
		}
	case glue.APP_CMD_DESTROY:
		log.info("destroy command sent")
		state := (^State)(app.userData)
		state.should_quit = true
	}
	if cmd == glue.APP_CMD_INIT_WINDOW {
		state.app_has_been_init = true
		when !RENDER_ASAP do android.AChoreographer_postFrameCallback64(
			android.AChoreographer_getInstance(),
			frame_cb,
			app,
		)
	}
}

on_input_event :: proc(
	app: ^glue.android_app,
	event: ^android.AInputEvent,
) -> (handled: b32) {
	if android.AInputEvent_getType(event) != .MOTION || app.window == nil {
		return false
	}

	#partial switch android.AMotionEvent_getAction(event).action {
	case .DOWN, .MOVE:
		state := (^State)(app.userData)

		state.last_touch_pos = {
			int(android.AMotionEvent_getX(event, 0)),
			int(android.AMotionEvent_getY(event, 0)),
		}
	}
	return true
}

transform :: proc(vertex: [3]f64, by: matrix[4, 4]f64) -> [3]f64 {
	return (by*[4]f64{vertex.x, vertex.y, vertex.z, 1}).xyz
}
project_to_screenspace :: proc(vertex: [3]f64, pers: matrix[4, 4]f64) -> [3]f64 {
	transformed := pers*[4]f64{vertex.x, vertex.y, vertex.z, 1}
	return transformed.xyz/transformed.w
}
draw_triangle_colored :: proc(canvas: ^Canvas3D, triangle: [3][3]f64, colors: [3]Color) -> [3][2]int {
	float_to_screen :: proc(w,h:int, posf:[2]f64) -> (posi: [2]int) {
		// TODO: 1 -> w or h, it should map to w-1 or h-1?
		return auto_cast((posf+1)/2 * [2]f64{f64(w),f64(h)})
	}
	triangle_screen_coords := [3][2]int {
		float_to_screen(canvas.width, canvas.height, triangle[0].xy),
		float_to_screen(canvas.width, canvas.height, triangle[1].xy),
		float_to_screen(canvas.width, canvas.height, triangle[2].xy),
	}
	triangle_depth := [3]f64 { triangle[0].z, triangle[1].z, triangle[2].z }

	x1 := triangle_screen_coords[0].x
	x2 := triangle_screen_coords[1].x
	x3 := triangle_screen_coords[2].x
	y1 := triangle_screen_coords[0].y
	y2 := triangle_screen_coords[1].y
	y3 := triangle_screen_coords[2].y

	edge1 := [2]int { x2-x1, y2-y1 }
	edge2 := [2]int { x3-x1, y3-y1 }
	D := edge1.x*edge2.y - edge2.x*edge1.y
	if D == 0 do return {}
	factor := D < 0 ? -1 : 1
	D *= factor

	xmin := min(x1, x2, x3)
	ymin := min(y1, y2, y3)
	xmax := max(x1, x2, x3)
	ymax := max(y1, y2, y3)

	xmin = clamp(xmin, 0, canvas.width-1)
	ymin = clamp(ymin, 0, canvas.height-1)
	xmax = clamp(xmax, 0, canvas.width-1)
	ymax = clamp(ymax, 0, canvas.height-1)

	for y in ymin..=ymax {
		l1 := ((xmin-x1)*edge2.y - (y-y1)*edge2.x)*factor
		l2 := (-(xmin-x1)*edge1.y + (y-y1)*edge1.x)*factor
		for x in xmin..=xmax {
			//l1 := ((x-x1)*edge2.y - (y-y1)*edge2.x)*factor
			//l2 := (-(x-x1)*edge1.y + (y-y1)*edge1.x)*factor
			defer {
				l1 += edge2.y*factor
				l2 -= edge1.y*factor
			}

			if l1 < 0 || l2 < 0 || D < l1+l2 do continue

			w0 := D-l1-l2
			w1 := l1
			w2 := l2

			depth := (
				triangle_depth[0]*f64(w0) +
				triangle_depth[1]*f64(w1) +
				triangle_depth[2]*f64(w2) \
			)/f64(D)
			if depth < -1 || 1 < depth do continue
			color := Color((
				([4]int)(colors[0])*w0 +
				([4]int)(colors[1])*w1 +
				([4]int)(colors[2])*w2 \
			)/D)

			if canvas_draw_depth_unsafe(canvas, x, y, depth) {
				canvas_draw_pixel_unsafe(canvas, x, y, color)
			}
		}
	}

	return triangle_screen_coords
}

draw :: proc(app: ^glue.android_app, state: ^State) {
	if app.window == nil do return

	state := (^State)(app.userData)

	bg_color := Color {
		0xF0,
		u8(state.last_touch_pos.x*255/state.window_size.x),
		u8(state.last_touch_pos.y*255/state.window_size.y),
		0xFF,
	}

	android.ANativeWindow_setBuffersGeometry(app.window, 0, 0, .R8G8B8A8_UNORM)
	buffer: android.ANativeWindow_Buffer
	if android.ANativeWindow_lock(app.window, &buffer, nil) != 0 {
		return
	}
	defer android.ANativeWindow_unlockAndPost(app.window)

	float_to_screen :: proc(w,h:int, xf,yf: f64) -> (xi,yi: int) {
		// TODO: 1 -> w or h, it should map to w-1 or h-1?
		return int((xf+1)/2*f64(w)), int((yf+1)/2*f64(h))
	}

	canvas_resize(&state.canvas, int(buffer.width), int(buffer.height))
	canvas3d_resize(&state.canvas3d, int(buffer.width)/THREEDEE_GRAPHICS_SCALE, int(buffer.height)/THREEDEE_GRAPHICS_SCALE)
	//fmt.println("drawing:", state.canvas.width, state.canvas.height)
	canvas_fill(&state.canvas, {150,150,150,255}/*state.bg_color*/)
	for y in 0..<state.canvas3d.height-1 {
		for x in 0..<state.canvas3d.width-1 {
			#force_inline canvas_put_pixel_unsafe(&state.canvas3d, x, y, {})
			#force_inline canvas_put_depth_unsafe(&state.canvas3d, x, y, 1)
		}
	}

	pos_ratio := ([2]f64)(state.last_touch_pos)/[2]f64{f64(state.canvas.width),f64(state.canvas.height)}
	theta_y := (-math.TAU/8)*(1-pos_ratio.x) + (math.TAU/8)*pos_ratio.x
	theta_x := (-math.TAU/8)*(1-pos_ratio.y) + (math.TAU/8)*pos_ratio.y

	trans := linalg.matrix4_translate_f64({-0.5, 4, -3})
	rot_y := linalg.matrix4_rotate_f64(theta_y, {0,1,0})
	rot_x := linalg.matrix4_rotate_f64(theta_x, {1,0,0})
	view := linalg.matrix4_look_at_f64({0,0,-12}, {-0.5, 4, -3}, {0,1,0})
	proj := linalg.matrix4_perspective_f64(math.TAU/6, f64(state.canvas3d.width)/f64(state.canvas3d.height), 1, 1000)
	cube_trans := view*trans*rot_x*rot_y
	floor_trans := view*trans

	for triag, i in cube {
		transformed := [3][3]f64 {
			transform(triag[0], cube_trans),
			transform(triag[1], cube_trans),
			transform(triag[2], cube_trans),
		}
		screenspace := [3][3]f64 {
			project_to_screenspace(transformed[0], proj),
			project_to_screenspace(transformed[1], proj),
			project_to_screenspace(transformed[2], proj),
		}

		r := u8(20 + 200*i/(len(cube)-1))
		g := u8(200 - 200*i/(len(cube)-1))
		color := Color {r, g, 150, 255}

		if i < 2 {
			coords := draw_triangle_colored(
				&state.canvas3d, screenspace,
				{bg_color,bg_color,bg_color},
			)
			draw_triangle_outline(
				&state.canvas, coords*THREEDEE_GRAPHICS_SCALE,
				bg_color,
			)
		} else {
			coords := draw_triangle_colored(
				&state.canvas3d, screenspace,
				{color,color,color},
			)
			draw_triangle_outline(
				&state.canvas, coords*THREEDEE_GRAPHICS_SCALE,
				color,
			)
		}
	}
	for triag in floor {
		transformed := [3][3]f64 {
			transform(triag[0], floor_trans),
			transform(triag[1], floor_trans),
			transform(triag[2], floor_trans),
		}
		screenspace := [3][3]f64 {
			project_to_screenspace(transformed[0], proj),
			project_to_screenspace(transformed[1], proj),
			project_to_screenspace(transformed[2], proj),
		}

		coords := draw_triangle_colored(
			&state.canvas3d, screenspace,
			{{255,0,0,255},{0,255,0,255},{0,0,255,255}},
		)
		draw_triangle_outline(&state.canvas, coords*THREEDEE_GRAPHICS_SCALE, {255,255,255,255})
	}

	for y in 0..<state.canvas3d.height {
		for ysub in 0..<THREEDEE_GRAPHICS_SCALE {
			y_outer := y*THREEDEE_GRAPHICS_SCALE + ysub
			for x in 0..<state.canvas3d.width {
				color: Color
				#no_bounds_check {
				color = state.canvas3d.data[y*state.canvas3d.stride + x]
				}
				if color.a == 0 do continue
				for xsub in 0..<THREEDEE_GRAPHICS_SCALE {
					x_outer := x*THREEDEE_GRAPHICS_SCALE + xsub
					canvas_draw_pixel_unsafe(
						&state.canvas,
						x_outer, y_outer,
						color,
					)
				}
			}
		}
	}

	draw_rect(&state.canvas, {10,16,64,128}, {0,100,200,255})
	draw_rect_outline(&state.canvas, {64,128,256,512}, {0,0,0,255})
	draw_line(
		&state.canvas,
		{state.canvas.width/2, state.canvas.height/2},
		state.last_touch_pos,
		{0,0,0,255},
	)

	draw_triangle(&state.canvas, {
		{550,550},
		{750,500},
		{500,750},
	}, {255,255,255,127}, debug=true)

	pixels := ([^]Color)(buffer.bits)
	for y in 0..<state.canvas.height {
		for x in 0..<state.canvas.width {
			pixels[y*int(buffer.stride) + x] = state.canvas.data[y*state.canvas.stride + x]
		}
	}
}
