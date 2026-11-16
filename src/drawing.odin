package android_maze_explorer

Color :: [4]u8

color_blend :: #force_inline proc(bg_color, fg_color: Color) -> Color {
	bgi := cast([4]int)bg_color
	fgi := cast([4]int)fg_color
	return {
		u8((bgi.r*(255-fgi.a) + fgi.r*fgi.a)/255),
		u8((bgi.g*(255-fgi.a) + fgi.g*fgi.a)/255),
		u8((bgi.b*(255-fgi.a) + fgi.b*fgi.a)/255),
		bg_color.a + u8((255-bgi.a)*fgi.a/255),
	}
}

Point :: [2]int

draw_line :: proc(canvas: ^Canvas, p1, p2: Point, color: Color) {
	p1, p2 := p1, p2
	if p1.x > p2.x {
		p1, p2 = p2, p1
	}

	x1 := p1.x
	x2 := p2.x
	y1 := p1.y
	y2 := p2.y

	if x1 >= canvas.width do return
	if min(y1, y2) >= canvas.height do return

	if x2 < 0 do return
	if max(y1, y2) < 0 do return

	dx := x2 - x1
	dy := y2 - y1

	if dx == dy {
		lo := max(0, -x1, -y1)
		hi := min(dx, canvas.width-1-x1, canvas.height-1-y1)
		for i in lo..=hi {
			#force_inline canvas_draw_pixel(canvas, x1+i, y1+i, color)
		}
	} else if dx == -dy {
		lo := max(0, -x1, y1+1-canvas.height)
		hi := min(dx, canvas.width-1-x1, y1)
		for i in lo..=hi {
			#force_inline canvas_draw_pixel(canvas, x1+i, y1+i, color)
		}
	} else if dx == 0 {
		lo := max(0, min(y1, y2))
		hi := min(canvas.height-1, max(y1, y2))
		for y in lo..=hi {
			#force_inline canvas_draw_pixel(canvas, x1, y, color)
		}
	} else if dy == 0 {
		lo := max(0, x1)
		hi := min(canvas.width-1, x2)
		for x in lo..=hi {
			#force_inline canvas_draw_pixel(canvas, x, y1, color)
		}
	} else if dx > abs(dy) {
		y_offset := dy > 0 ? 1 : -1
		dy = abs(dy)

		D := 2*dy - dx

		y := y1
		for x in x1..=x2 {
			if x >= canvas.width do break
			if y_offset == -1 && y < 0 do break
			else if y_offset == 1 && y >= canvas.height do break
			if 0 <= x && 0 <= y && y < canvas.height {
				#force_inline canvas_draw_pixel(canvas, x, y, color)
			}
			if D > 0 {
				y += y_offset
				D += 2*(dy - dx)
			} else {
				D += 2*dy
			}
		}
	} else {
		pos_slope := dy > 0
		dy = abs(dy)

		D := 2*dx - dy

		if pos_slope {
			x := x1
			for y in y1..=y2 {
				if x >= canvas.width do break
				if y >= canvas.height do break
				if 0 <= x && 0 <= y {
					#force_inline canvas_draw_pixel(canvas, x, y, color)
				}
				if D > 0 {
					x += 1
					D += 2*(dx - dy)
				} else {
					D += 2*dx
				}
			}
		} else {
			x := x2
			for y in y2..=y1 {
				if x < 0 do break
				if y >= canvas.height do break
				if x < canvas.width && 0 <= y {
					#force_inline canvas_draw_pixel(canvas, x, y, color)
				}
				if D > 0 {
					x -= 1
					D += 2*(dx - dy)
				} else {
					D += 2*dx
				}
			}
		}
	}
}

ONLY_CC_TRIANGLES :: #config(ONLY_CC_TRIANGLES, false)

Triangle2D :: [3][2]int

draw_triangle_outline :: proc(canvas: ^Canvas, triangle: Triangle2D, color: Color) {
	when ONLY_CC_TRIANGLES {
		edge_from_fst_corner_to_scd := triangle[1] - triangle[0]
		edge_from_fst_corner_to_thd := triangle[2] - triangle[0]
		// |cross(v1, v2)| = |v1||v2|sin theta
		c_times_sin_theta := (
			edge_from_fst_corner_to_scd.x*edge_from_fst_corner_to_thd.y -
			edge_from_fst_corner_to_thd.x*edge_from_fst_corner_to_scd.y \
		)
		// counter-clockwise iff sin theta > 0
		if c_times_sin_theta <= 0 do return
	}
	draw_line(canvas, triangle[0], triangle[1], color)
	draw_line(canvas, triangle[1], triangle[2], color)
	draw_line(canvas, triangle[2], triangle[0], color)
}

draw_triangle :: proc(canvas: ^Canvas, triangle: Triangle2D, color: Color, debug:=false) {
	x0 := triangle[0].x
	x1 := triangle[1].x
	x2 := triangle[2].x
	y0 := triangle[0].y
	y1 := triangle[1].y
	y2 := triangle[2].y

	edge01 := triangle[1]-triangle[0]
	edge02 := triangle[2]-triangle[0]
	trapazoid_area := edge01.x*edge02.y - edge02.x*edge01.y
	when ONLY_CC_TRIANGLES do if trapazoid_area <= 0 do return
	else do if trapazoid_area == 0 do return
	area_sign := 1
	when !ONLY_CC_TRIANGLES {
		area_sign = trapazoid_area < 0 ? -1 : 1
		trapazoid_area = abs(trapazoid_area)
	}

	xmin := min(x0, x1, x2)
	ymin := min(y0, y1, y2)
	xmax := max(x0, x1, x2)
	ymax := max(y0, y1, y2)

	if xmin >= canvas.width do return
	if ymin >= canvas.height do return
	if xmax < 0 do return
	if ymax < 0 do return

	xmin = clamp(xmin, 0, canvas.width-1)
	ymin = clamp(ymin, 0, canvas.height-1)
	xmax = clamp(xmax, 0, canvas.width-1)
	ymax = clamp(ymax, 0, canvas.height-1)

	for y in ymin..=ymax {
		for x in xmin..=xmax {
			// distance away from vertex 0 in the direction of vertex 1
			l1 := (x-x0)*edge02.y - (y-y0)*edge02.x
			// distance away from vertex 0 in the direction of vertex 2
			l2 := (y-y0)*edge01.x - (x-x0)*edge01.y

			if l1 < 0 {
				if debug do canvas_draw_pixel_unsafe(
					canvas,
					x, y,
					{0,color.g,color.b,color.a},
				)
			} else if l2 < 0 {
				if debug do canvas_draw_pixel_unsafe(
					canvas,
					x, y,
					{color.r,0,color.b,color.a},
				)
			} else if trapazoid_area < l1 + l2 {
				if debug do canvas_draw_pixel_unsafe(
					canvas,
					x, y,
					{color.r,color.g,0,color.a},
				)
			} else {
				canvas_draw_pixel_unsafe(canvas, x, y, color)
			}
		}
	}
}

Rectangle :: struct {
	x, y: int,
	width, height: int,
}

draw_rect_outline :: proc(canvas: ^Canvas, rectangle: Rectangle, color: Color) #no_bounds_check {
	ensure(rectangle.width >= 0 && rectangle.height >= 0)

	if rectangle.width == 0 || rectangle.height == 0 do return

	x1 := rectangle.x
	x2 := rectangle.x + rectangle.width - 1
	y1 := rectangle.y
	y2 := rectangle.y + rectangle.height - 1

	if x1 >= canvas.width do return
	if y1 >= canvas.height do return

	if x2 < 0 do return
	if y2 < 0 do return

	left_edge_outside := x1 < 0
	top_edge_outside := y1 < 0
	right_edge_outside := x2 >= canvas.width
	bottom_edge_outside := y2 >= canvas.height

	xmin := clamp(x1, 0, canvas.width-1)
	ymin := clamp(y1, 0, canvas.height-1)
	xmax := clamp(x2, 0, canvas.width-1)
	ymax := clamp(y2, 0, canvas.height-1)

	if left_edge_outside && right_edge_outside {
	} else if left_edge_outside {
		for y in ymin..=ymax {
			#force_inline canvas_draw_pixel_unsafe(canvas, x2, y, color)
		}
	} else if right_edge_outside {
		for y in ymin..=ymax {
			#force_inline canvas_draw_pixel_unsafe(canvas, x1, y, color)
		}
	} else {
		for y in ymin..=ymax {
			#force_inline canvas_draw_pixel_unsafe(canvas, x1, y, color)
			#force_inline canvas_draw_pixel_unsafe(canvas, x2, y, color)
		}
	}

	if top_edge_outside && bottom_edge_outside {
	} else if top_edge_outside {
		for x in xmin..=xmax {
			#force_inline canvas_draw_pixel_unsafe(canvas, x, y2, color)
		}
	} else if bottom_edge_outside {
		for x in xmin..=xmax {
			#force_inline canvas_draw_pixel_unsafe(canvas, x, y1, color)
		}
	} else {
		for x in xmin..=xmax {
			#force_inline canvas_draw_pixel_unsafe(canvas, x, y1, color)
			#force_inline canvas_draw_pixel_unsafe(canvas, x, y2, color)
		}
	}
}
draw_rect :: proc(canvas: ^Canvas, rectangle: Rectangle, color: Color) #no_bounds_check {
	ensure(rectangle.width >= 0 && rectangle.height >= 0)

	if rectangle.width == 0 || rectangle.height == 0 do return

	x1 := rectangle.x
	x2 := rectangle.x + rectangle.width - 1
	y1 := rectangle.y
	y2 := rectangle.y + rectangle.height - 1

	if x1 >= canvas.width do return
	if y1 >= canvas.height do return

	if x2 < 0 do return
	if y2 < 0 do return

	xmin := clamp(x1, 0, canvas.width-1)
	ymin := clamp(y1, 0, canvas.height-1)
	xmax := clamp(x2, 0, canvas.width-1)
	ymax := clamp(y2, 0, canvas.height-1)

	for y in ymin..=ymax {
		for x in xmin..=ymax {
			#force_inline canvas_draw_pixel_unsafe(canvas, x, y, color)
		}
	}
}
