package android_maze_explorer

Canvas :: struct {
	width: int,
	height: int,
	stride: int,
	data: []Color,
}
Canvas3D :: struct {
	using canvas: Canvas,
	depth: []f64,
}

canvas_make :: proc(width, height, stride: int, allocator := context.allocator) -> Canvas {
	ensure(width <= stride)
	return { width, height, stride, make([]Color, stride*height, allocator=allocator) }
}
canvas3d_make :: proc(width, height, stride: int, allocator := context.allocator) -> Canvas3D {
	return { canvas_make(width, height, stride, allocator), make([]f64, stride*height, allocator=allocator) }
}
canvas_resize :: proc(
	canvas: ^Canvas,
	width, height: int,
	allocator := context.allocator,
	preserve_content := true,
) {
	if width <= canvas.stride && height <= len(canvas.data)/canvas.stride {
		canvas.width = width
		canvas.height = height
	} else {
		old_width := canvas.width
		old_height := canvas.height
		old_stride := canvas.stride
		canvas.width = width
		canvas.height = height
		canvas.stride = max(canvas.width, canvas.stride)
		new_size := canvas.stride*max(canvas.height, old_height)
		new_data := make([]Color, new_size, allocator=allocator)
		if preserve_content {
			for y in 0..<min(old_height, height) {
				for x in 0..<min(old_width, width) {
					new_idx := y*canvas.stride + x
					old_idx := y*old_stride + x
					new_data[new_idx] = canvas.data[old_idx]
				}
			}
		}
		delete(canvas.data)
		canvas.data = new_data
	}
}
canvas3d_resize :: proc(
	canvas: ^Canvas3D,
	width, height: int,
	allocator := context.allocator,
	preserve_content := true,
) {
	if width <= canvas.stride && height <= len(canvas.data)/canvas.stride {
		canvas.width = width
		canvas.height = height
	} else {
		old_width := canvas.width
		old_height := canvas.height
		old_stride := canvas.stride
		canvas.width = width
		canvas.height = height
		canvas.stride = max(canvas.width, canvas.stride)
		new_size := canvas.stride*max(canvas.height, old_height)
		new_data := make([]Color, new_size, allocator=allocator)
		new_depth := make([]f64, new_size, allocator=allocator)
		if preserve_content {
			for y in 0..<min(old_height, height) {
				for x in 0..<min(old_width, width) {
					new_idx := y*canvas.stride + x
					old_idx := y*old_stride + x
					new_data[new_idx] = canvas.data[old_idx]
					new_depth[new_idx] = canvas.depth[old_idx]
				}
			}
		}
		delete(canvas.data)
		delete(canvas.depth)
		canvas.data = new_data
		canvas.depth = new_depth
	}
}
canvas_put_pixel :: proc(canvas: ^Canvas, x, y: int, color: Color) {
	canvas.data[y*canvas.stride + x] = color
}
canvas_put_pixel_unsafe :: proc(canvas: ^Canvas, x, y: int, color: Color) #no_bounds_check {
	canvas.data[y*canvas.stride + x] = color
}
canvas_put_depth :: proc(canvas: ^Canvas3D, x, y: int, depth: f64) {
	canvas.depth[y*canvas.stride + x] = depth
}
canvas_put_depth_unsafe :: proc(canvas: ^Canvas3D, x, y: int, depth: f64) #no_bounds_check {
	canvas.depth[y*canvas.stride + x] = depth
}
canvas_draw_depth :: proc(canvas: ^Canvas3D, x, y: int, depth: f64) -> (ok: bool) {
	if canvas.depth[y*canvas.stride + x] <= depth do return false
	#force_inline canvas_put_depth(canvas, x, y, depth)
	return true
}
canvas_draw_depth_unsafe :: proc(canvas: ^Canvas3D, x, y: int, depth: f64) -> (ok: bool) #no_bounds_check {
	if canvas.depth[y*canvas.stride + x] <= depth do return false
	#force_inline canvas_put_depth_unsafe(canvas, x, y, depth)
	return true
}
import "core:fmt"
canvas_draw_pixel :: proc(canvas: ^Canvas, x, y: int, color: Color, loc := #caller_location) {
	if y >= canvas.height || x >= canvas.width do fmt.panicf("",loc)
	if color.a == 255 do canvas.data[y*canvas.stride + x] = color
	else if color.a == 0 do return
	else {
		canvas.data[y*canvas.stride + x] = color_blend(
			canvas.data[y*canvas.stride + x],
			color,
		)
	}
}
canvas_draw_pixel_unsafe :: proc(canvas: ^Canvas, x, y: int, color: Color) #no_bounds_check {
	if color.a == 255 do canvas.data[y*canvas.stride + x] = color
	else if color.a == 0 do return
	else {
		canvas.data[y*canvas.stride + x] = color_blend(
			canvas.data[y*canvas.stride + x],
			color,
		)
	}
}
canvas_fill :: proc(canvas: ^Canvas, color: Color) #no_bounds_check {
	for y in 0..<canvas.height {
		for x in 0..<canvas.width {
			#force_inline canvas_put_pixel_unsafe(canvas, x, y, color)
		}
	}
}
canvas3d_reset :: proc(canvas: ^Canvas3D) #no_bounds_check {
	for y in 0..<canvas.height {
		for x in 0..<canvas.width {
			#force_inline canvas_put_pixel_unsafe(canvas, x, y, {})
			#force_inline canvas_put_depth_unsafe(canvas, x, y, 1)
		}
	}
}
