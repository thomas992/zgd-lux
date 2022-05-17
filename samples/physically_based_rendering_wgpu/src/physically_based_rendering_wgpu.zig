const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const glfw = @import("glfw");
const zgpu = @import("zgpu");
const gpu = zgpu.gpu;
const c = zgpu.cimgui;
const zm = @import("zmath");
const zmesh = @import("zmesh");
const wgsl = @import("physically_based_rendering_wgsl.zig");

const content_dir = @import("build_options").content_dir;
const window_title = "zig-gamedev: physically based rendering (wgpu)";

const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    texcoord: [2]f32,
    tangent: [4]f32,
};

const Mesh = struct {
    index_offset: u32,
    vertex_offset: i32,
    num_indices: u32,
    num_vertices: u32,
};

const num_mesh_textures = 4;
const cube_mesh = 0;
const helmet_mesh = 1;
const enable_async_shader_compilation = true;

const FrameUniforms = struct {
    world_to_clip: zm.Mat,
};

const DrawUniforms = struct {
    object_to_world: zm.Mat,
};

const DemoState = struct {
    gctx: *zgpu.GraphicsContext,

    mesh_pipe: zgpu.RenderPipelineHandle = .{},

    vertex_buf: zgpu.BufferHandle,
    index_buf: zgpu.BufferHandle,

    depth_tex: zgpu.TextureHandle,
    depth_texv: zgpu.TextureViewHandle,

    mesh_tex: [num_mesh_textures]zgpu.TextureHandle,
    mesh_texv: [num_mesh_textures]zgpu.TextureViewHandle,

    aniso_sam: zgpu.SamplerHandle,

    frame_uniforms_bg: zgpu.BindGroupHandle,
    mesh_bg: zgpu.BindGroupHandle,

    meshes: std.ArrayList(Mesh),

    camera: struct {
        position: [3]f32 = .{ 2.2, 0.0, 2.2 },
        forward: [3]f32 = .{ 0.0, 0.0, 0.0 },
        pitch: f32 = 0.0,
        yaw: f32 = math.pi + 0.25 * math.pi,
    } = .{},
    mouse: struct {
        cursor: glfw.Window.CursorPos = .{ .xpos = 0.0, .ypos = 0.0 },
    } = .{},
};

fn loadAllMeshes(
    arena: std.mem.Allocator,
    out_meshes: *std.ArrayList(Mesh),
    out_vertices: *std.ArrayList(Vertex),
    out_indices: *std.ArrayList(u32),
) !void {
    var indices = std.ArrayList(u32).init(arena);
    var positions = std.ArrayList([3]f32).init(arena);
    var normals = std.ArrayList([3]f32).init(arena);
    var texcoords = std.ArrayList([2]f32).init(arena);
    var tangents = std.ArrayList([4]f32).init(arena);

    {
        const pre_indices_len = indices.items.len;
        const pre_positions_len = positions.items.len;

        const data = try zmesh.io.parseAndLoadFile(content_dir ++ "cube.gltf");
        defer zmesh.io.cgltf.free(data);
        try zmesh.io.appendMeshPrimitive(data, 0, 0, &indices, &positions, &normals, &texcoords, &tangents);

        try out_meshes.append(.{
            .index_offset = @intCast(u32, pre_indices_len),
            .vertex_offset = @intCast(i32, pre_positions_len),
            .num_indices = @intCast(u32, indices.items.len - pre_indices_len),
            .num_vertices = @intCast(u32, positions.items.len - pre_positions_len),
        });
    }
    {
        const pre_indices_len = indices.items.len;
        const pre_positions_len = positions.items.len;

        const data = try zmesh.io.parseAndLoadFile(content_dir ++ "SciFiHelmet/SciFiHelmet.gltf");
        defer zmesh.io.cgltf.free(data);
        try zmesh.io.appendMeshPrimitive(data, 0, 0, &indices, &positions, &normals, &texcoords, &tangents);

        try out_meshes.append(.{
            .index_offset = @intCast(u32, pre_indices_len),
            .vertex_offset = @intCast(i32, pre_positions_len),
            .num_indices = @intCast(u32, indices.items.len - pre_indices_len),
            .num_vertices = @intCast(u32, positions.items.len - pre_positions_len),
        });
    }

    try out_indices.ensureTotalCapacity(indices.items.len);
    for (indices.items) |mesh_index| {
        out_indices.appendAssumeCapacity(mesh_index);
    }

    try out_vertices.ensureTotalCapacity(positions.items.len);
    for (positions.items) |_, index| {
        out_vertices.appendAssumeCapacity(.{
            .position = positions.items[index],
            .normal = normals.items[index],
            .texcoord = texcoords.items[index],
            .tangent = tangents.items[index],
        });
    }
}

fn init(allocator: std.mem.Allocator, window: glfw.Window) !*DemoState {
    const gctx = try zgpu.GraphicsContext.init(allocator, window);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    //
    // Create bind group layouts.
    //
    const frame_uniforms_bgl = gctx.createBindGroupLayout(&.{
        zgpu.bglBuffer(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
    });
    defer gctx.destroyResource(frame_uniforms_bgl);

    const mesh_bgl = gctx.createBindGroupLayout(&.{
        zgpu.bglBuffer(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        zgpu.bglTexture(1, .{ .fragment = true }, .float, .dimension_2d, false),
        zgpu.bglSampler(2, .{ .fragment = true }, .filtering),
    });
    defer gctx.destroyResource(mesh_bgl);

    //
    // Create meshes.
    //
    zmesh.init(arena);
    defer zmesh.deinit();

    var meshes = std.ArrayList(Mesh).init(allocator);
    var vertices = std.ArrayList(Vertex).init(arena);
    var indices = std.ArrayList(u32).init(arena);
    try loadAllMeshes(arena, &meshes, &vertices, &indices);

    const total_num_vertices = @intCast(u32, vertices.items.len);
    const total_num_indices = @intCast(u32, indices.items.len);

    // Create a vertex buffer.
    const vertex_buf = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = total_num_vertices * @sizeOf(Vertex),
    });
    gctx.queue.writeBuffer(gctx.lookupResource(vertex_buf).?, 0, Vertex, vertices.items);

    // Create an index buffer.
    const index_buf = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .index = true },
        .size = total_num_indices * @sizeOf(u32),
    });
    gctx.queue.writeBuffer(gctx.lookupResource(index_buf).?, 0, u32, indices.items);

    //
    // Create textures and samplers.
    //
    const aniso_sam = gctx.createSampler(.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_filter = .linear,
        .max_anisotropy = 16,
    });

    // Create a depth texture and its 'view'.
    const depth = createDepthTexture(gctx);

    // Create mesh textures.
    const mesh_texture_paths = &[num_mesh_textures][:0]const u8{
        content_dir ++ "SciFiHelmet/SciFiHelmet_AmbientOcclusion.png",
        content_dir ++ "SciFiHelmet/SciFiHelmet_BaseColor.png",
        content_dir ++ "SciFiHelmet/SciFiHelmet_MetallicRoughness.png",
        content_dir ++ "SciFiHelmet/SciFiHelmet_Normal.png",
    };
    var mesh_tex: [num_mesh_textures]zgpu.TextureHandle = undefined;
    var mesh_texv: [num_mesh_textures]zgpu.TextureViewHandle = undefined;

    for (mesh_texture_paths) |path, tex_index| {
        var image = try zgpu.stbi.Image(u8).init(path, 4);
        defer image.deinit();

        mesh_tex[tex_index] = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = image.width,
                .height = image.height,
                .depth_or_array_layers = 1,
            },
            .format = .rgba8_unorm,
            .mip_level_count = math.log2_int(u32, math.max(image.width, image.height)) + 1,
        });
        mesh_texv[tex_index] = gctx.createTextureView(mesh_tex[tex_index], .{});

        gctx.queue.writeTexture(
            &.{ .texture = gctx.lookupResource(mesh_tex[tex_index]).? },
            image.data,
            &.{
                .bytes_per_row = image.width * image.channels_in_memory,
                .rows_per_image = image.height,
            },
            &.{ .width = image.width, .height = image.height },
        );
    }

    // Generate mipmaps on the GPU.
    {
        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            for (mesh_tex) |texture| {
                gctx.generateMipmaps(arena, encoder, texture);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();
        gctx.submit(&.{commands});
    }

    //
    // Create bind groups.
    //
    const frame_uniforms_bg = gctx.createBindGroup(frame_uniforms_bgl, &[_]zgpu.BindGroupEntryInfo{
        .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = 256 },
    });

    const mesh_bg = gctx.createBindGroup(mesh_bgl, &[_]zgpu.BindGroupEntryInfo{
        .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = 256 },
        .{ .binding = 1, .texture_view_handle = mesh_texv[0] },
        .{ .binding = 2, .sampler_handle = aniso_sam },
    });

    const demo = try allocator.create(DemoState);
    demo.* = .{
        .gctx = gctx,
        .vertex_buf = vertex_buf,
        .index_buf = index_buf,
        .depth_tex = depth.tex,
        .depth_texv = depth.texv,
        .mesh_tex = mesh_tex,
        .mesh_texv = mesh_texv,
        .aniso_sam = aniso_sam,
        .frame_uniforms_bg = frame_uniforms_bg,
        .mesh_bg = mesh_bg,
        .meshes = meshes,
    };

    //
    // Create pipelines.
    //
    createMeshPipeline(allocator, gctx, &.{ frame_uniforms_bgl, mesh_bgl }, &demo.mesh_pipe);

    return demo;
}

fn deinit(allocator: std.mem.Allocator, demo: *DemoState) void {
    demo.meshes.deinit();
    demo.gctx.deinit(allocator);
    allocator.destroy(demo);
}

fn update(demo: *DemoState) void {
    zgpu.gui.newFrame(demo.gctx.swapchain_descriptor.width, demo.gctx.swapchain_descriptor.height);

    if (c.igBegin("Demo Settings", null, c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoResize)) {
        c.igBulletText(
            "Average :  %.3f ms/frame (%.1f fps)",
            demo.gctx.stats.average_cpu_time,
            demo.gctx.stats.fps,
        );
        c.igBulletText("Right Mouse Button + drag :  rotate camera", "");
        c.igBulletText("W, A, S, D :  move camera", "");
    }
    c.igEnd();

    const window = demo.gctx.window;

    // Handle camera rotation with mouse.
    {
        const cursor = window.getCursorPos() catch unreachable;
        const delta_x = @floatCast(f32, cursor.xpos - demo.mouse.cursor.xpos);
        const delta_y = @floatCast(f32, cursor.ypos - demo.mouse.cursor.ypos);
        demo.mouse.cursor.xpos = cursor.xpos;
        demo.mouse.cursor.ypos = cursor.ypos;

        if (window.getMouseButton(.right) == .press) {
            demo.camera.pitch += 0.0025 * delta_y;
            demo.camera.yaw += 0.0025 * delta_x;
            demo.camera.pitch = math.min(demo.camera.pitch, 0.48 * math.pi);
            demo.camera.pitch = math.max(demo.camera.pitch, -0.48 * math.pi);
            demo.camera.yaw = zm.modAngle(demo.camera.yaw);
        }
    }

    // Handle camera movement with 'WASD' keys.
    {
        const speed = zm.f32x4s(2.0);
        const delta_time = zm.f32x4s(demo.gctx.stats.delta_time);
        const transform = zm.mul(zm.rotationX(demo.camera.pitch), zm.rotationY(demo.camera.yaw));
        var forward = zm.normalize3(zm.mul(zm.f32x4(0.0, 0.0, 1.0, 0.0), transform));

        zm.store(demo.camera.forward[0..], forward, 3);

        const right = speed * delta_time * zm.normalize3(zm.cross3(zm.f32x4(0.0, 1.0, 0.0, 0.0), forward));
        forward = speed * delta_time * forward;

        var cpos = zm.load(demo.camera.position[0..], zm.Vec, 3);

        if (window.getKey(.w) == .press) {
            cpos += forward;
        } else if (window.getKey(.s) == .press) {
            cpos -= forward;
        }
        if (window.getKey(.d) == .press) {
            cpos += right;
        } else if (window.getKey(.a) == .press) {
            cpos -= right;
        }

        zm.store(demo.camera.position[0..], cpos, 3);
    }
}

fn draw(demo: *DemoState) void {
    const gctx = demo.gctx;
    const fb_width = gctx.swapchain_descriptor.width;
    const fb_height = gctx.swapchain_descriptor.height;

    const cam_world_to_view = zm.lookToLh(
        zm.load(demo.camera.position[0..], zm.Vec, 3),
        zm.load(demo.camera.forward[0..], zm.Vec, 3),
        zm.f32x4(0.0, 1.0, 0.0, 0.0),
    );
    const cam_view_to_clip = zm.perspectiveFovLh(
        0.25 * math.pi,
        @intToFloat(f32, fb_width) / @intToFloat(f32, fb_height),
        0.01,
        200.0,
    );
    const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Main pass.
        pass: {
            const vb_info = gctx.lookupResourceInfo(demo.vertex_buf) orelse break :pass;
            const ib_info = gctx.lookupResourceInfo(demo.index_buf) orelse break :pass;
            const mesh_pipe = gctx.lookupResource(demo.mesh_pipe) orelse break :pass;
            const frame_uniforms_bg = gctx.lookupResource(demo.frame_uniforms_bg) orelse break :pass;
            const mesh_bg = gctx.lookupResource(demo.mesh_bg) orelse break :pass;
            const depth_texv = gctx.lookupResource(demo.depth_texv) orelse break :pass;

            const color_attachment = gpu.RenderPassColorAttachment{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
            };
            const depth_attachment = gpu.RenderPassDepthStencilAttachment{
                .view = depth_texv,
                .depth_load_op = .clear,
                .depth_store_op = .store,
                .depth_clear_value = 1.0,
            };
            const render_pass_info = gpu.RenderPassEncoder.Descriptor{
                .color_attachments = &.{color_attachment},
                .depth_stencil_attachment = &depth_attachment,
            };
            const pass = encoder.beginRenderPass(&render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
            pass.setIndexBuffer(ib_info.gpuobj.?, .uint32, 0, ib_info.size);

            pass.setPipeline(mesh_pipe);

            // Update "world to clip" (camera) xform.
            {
                const mem = gctx.uniformsAllocate(FrameUniforms, 1);
                mem.slice[0].world_to_clip = zm.transpose(cam_world_to_clip);

                pass.setBindGroup(0, frame_uniforms_bg, &.{mem.offset});
            }

            // Update "object to world" xform.
            const object_to_world = zm.identity();

            const mem = gctx.uniformsAllocate(DrawUniforms, 1);
            mem.slice[0].object_to_world = zm.transpose(object_to_world);

            pass.setBindGroup(1, mesh_bg, &.{mem.offset});

            // Draw mesh.
            pass.drawIndexed(
                demo.meshes.items[helmet_mesh].num_indices,
                1,
                demo.meshes.items[helmet_mesh].index_offset,
                demo.meshes.items[helmet_mesh].vertex_offset,
                0,
            );
        }

        // Gui pass.
        {
            const color_attachment = gpu.RenderPassColorAttachment{
                .view = back_buffer_view,
                .load_op = .load,
                .store_op = .store,
            };
            const render_pass_info = gpu.RenderPassEncoder.Descriptor{
                .color_attachments = &.{color_attachment},
            };
            const pass = encoder.beginRenderPass(&render_pass_info);
            defer {
                pass.end();
                pass.release();
            }
            zgpu.gui.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});

    if (gctx.present() == .swap_chain_resized) {
        // Release old depth texture.
        gctx.destroyResource(demo.depth_texv);
        gctx.destroyResource(demo.depth_tex);

        // Create a new depth texture to match the new window size.
        const depth = createDepthTexture(gctx);
        demo.depth_tex = depth.tex;
        demo.depth_texv = depth.texv;
    }
}

fn createDepthTexture(gctx: *zgpu.GraphicsContext) struct {
    tex: zgpu.TextureHandle,
    texv: zgpu.TextureViewHandle,
} {
    const tex = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .dimension_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const texv = gctx.createTextureView(tex, .{});
    return .{ .tex = tex, .texv = texv };
}

fn createMeshPipeline(
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    bind_group_layouts: []const zgpu.BindGroupLayoutHandle,
    out_pipeline: *zgpu.RenderPipelineHandle,
) void {
    const pipeline_layout = gctx.createPipelineLayout(bind_group_layouts);
    defer gctx.destroyResource(pipeline_layout);

    const module_vs = gctx.device.createShaderModule(&.{
        .label = "mesh_vs",
        .code = .{ .wgsl = wgsl.mesh_vs },
    });
    defer module_vs.release();

    const module_fs = gctx.device.createShaderModule(&.{
        .label = "mesh_fs",
        .code = .{ .wgsl = wgsl.mesh_fs },
    });
    defer module_fs.release();

    const color_target = gpu.ColorTargetState{
        .format = zgpu.GraphicsContext.swapchain_format,
        .blend = &.{ .color = .{}, .alpha = .{} },
    };

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "normal"), .shader_location = 1 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "texcoord"), .shader_location = 2 },
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "tangent"), .shader_location = 3 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout{
        .array_stride = @sizeOf(Vertex),
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };

    // Create a render pipeline.
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .vertex = gpu.VertexState{
            .module = module_vs,
            .entry_point = "main",
            .buffers = &.{vertex_buffer_layout},
        },
        .primitive = gpu.PrimitiveState{
            .front_face = .cw,
            .cull_mode = .back,
            .topology = .triangle_list,
        },
        .depth_stencil = &gpu.DepthStencilState{
            .format = .depth32_float,
            .depth_write_enabled = true,
            .depth_compare = .less,
        },
        .fragment = &gpu.FragmentState{
            .module = module_fs,
            .entry_point = "main",
            .targets = &.{color_target},
        },
    };

    if (enable_async_shader_compilation) {
        gctx.createRenderPipelineAsync(allocator, pipeline_layout, pipeline_descriptor, out_pipeline);
    } else {
        out_pipeline.* = gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
    }
}

pub fn main() !void {
    zgpu.checkContent(content_dir) catch {
        // In case of error zgpu.checkContent() will print error message.
        return;
    };

    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(1280, 960, window_title, null, null, .{
        .client_api = .no_api,
        .cocoa_retina_framebuffer = true,
    });
    defer window.destroy();
    try window.setSizeLimits(.{ .width = 400, .height = 400 }, .{ .width = null, .height = null });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const demo = try init(allocator, window);
    defer deinit(allocator, demo);

    zgpu.gui.init(window, demo.gctx.device, content_dir, "Roboto-Medium.ttf", 25.0);
    defer zgpu.gui.deinit();

    while (!window.shouldClose()) {
        try glfw.pollEvents();
        update(demo);
        draw(demo);
    }
}