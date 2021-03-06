# frozen_string_literal: true

# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache 2.0 license (see LICENSE).
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2020 Datadog, Inc.

require 'test_helper'

class MockProcessor
  def on_start(span, _parent_context); end

  def on_finish(span); end
end

describe OpenTelemetry::Exporters::Datadog::Exporter::SpanEncoder do
  let(:span_encoder) { OpenTelemetry::Exporters::Datadog::Exporter::SpanEncoder.new }

  it 'encodes a span_data' do
    encoded_span = span_encoder.translate_to_datadog([create_span_data], 'example_service')
    _(encoded_span[0].to_hash[:name]).must_equal('example_name')
    _(encoded_span[0].to_hash[:meta]).must_equal({})
  end

  it 'encodes attributes in the span but not the events' do
    attributes = { 'akey' => 'avalue' }
    events = [
      OpenTelemetry::SDK::Trace::Event.new(
        name: 'event', attributes: { 'ekey' => 'evalue' }
      )
    ]

    span_data = create_span_data(attributes: attributes, events: events)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.get_tag('akey')).must_equal('avalue')
    assert_nil(datadog_span_info.get_tag('ekey'))
  end

  it 'encodes array attribute values in the span as JSON strings' do
    attributes = { 'akey' => ['avalue'] }

    span_data = create_span_data(attributes: attributes)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.get_tag('akey')).must_equal('["avalue"]')
  end

  it 'generates a valid datadog resource' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }

    span_data = create_span_data(attributes: attributes)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.resource).must_equal('GET /example/api')
  end

  it 'translates otel spans to datadog spans' do
    span_names = %w[test1 test2 test3]
    trace_id = OpenTelemetry::Trace.generate_trace_id
    span_id = OpenTelemetry::Trace.generate_span_id
    parent_id = OpenTelemetry::Trace.generate_span_id
    other_id = OpenTelemetry::Trace.generate_span_id
    base_time = 683_647_322 * 10**9
    start_times = [base_time, base_time + 150 * 10**6, base_time + 300 * 10**6]
    durations = [50 * 10**6, 100 * 10**6, 200 * 10**6]
    end_times = [start_times[0] + durations[0], start_times[1] + durations[1], start_times[2] + durations[2]]
    instrumentation_library = OpenTelemetry::SDK::InstrumentationLibrary.new('OpenTelemetry::Instrumentation::Redis', 1)

    span_context = OpenTelemetry::Trace::SpanContext.new(trace_id: trace_id, span_id: span_id)
    parent_context = OpenTelemetry::Trace::SpanContext.new(trace_id: trace_id, span_id: parent_id, tracestate: '_dd_origin=synthetics-example')
    other_context = OpenTelemetry::Trace::SpanContext.new(trace_id: trace_id, span_id: other_id)
    otel_span_one = OpenTelemetry::SDK::Trace::Span.new(parent_context, nil, span_names[0], nil, nil, OpenTelemetry::SDK::Trace::Config::TraceConfig.new, MockProcessor.new, nil, nil, start_times[0], nil, instrumentation_library)
    otel_span_two = OpenTelemetry::SDK::Trace::Span.new(span_context, parent_context, span_names[1], nil, parent_id, OpenTelemetry::SDK::Trace::Config::TraceConfig.new, MockProcessor.new, nil, nil, start_times[1], nil, instrumentation_library)
    otel_span_three = OpenTelemetry::SDK::Trace::Span.new(other_context, nil, span_names[2], nil, nil, OpenTelemetry::SDK::Trace::Config::TraceConfig.new, MockProcessor.new, nil, nil, start_times[2], nil, instrumentation_library)
    otel_span_one.finish(end_timestamp: end_times[0])
    otel_span_two.finish(end_timestamp: end_times[1])
    otel_span_three.finish(end_timestamp: end_times[2])
    otel_spans = [otel_span_one.to_span_data, otel_span_two.to_span_data, otel_span_three.to_span_data]

    datadog_encoded_spans = span_encoder.translate_to_datadog(otel_spans, 'example_service')

    _(datadog_encoded_spans.length).must_equal 3

    datadog_encoded_spans.each_with_index do |span, idx|
      _(span.start_time).must_equal(start_times[idx])
      _(span.end_time).must_equal(end_times[idx])
    end

    _(datadog_encoded_spans[0].span_id).must_equal(datadog_encoded_spans[0].span_id)
    _(datadog_encoded_spans[0].trace_id).must_equal(datadog_encoded_spans[1].trace_id)
    _(datadog_encoded_spans[0].trace_id).must_equal(datadog_encoded_spans[2].trace_id)
    _(datadog_encoded_spans[0].span_type).must_equal(::Datadog::Contrib::Redis::Ext::TYPE)
    # check origin tag exists on parent only
    _(datadog_encoded_spans[0].get_tag('_dd_origin')).must_equal('synthetics-example')
    assert_nil(datadog_encoded_spans[1].get_tag('_dd_origin'))
    assert(!datadog_encoded_spans[0].trace_id.nil?)
    assert(!datadog_encoded_spans[0].span_id.nil?)
  end

  it 'generates a valid datadog span type' do
    instrumentation_library = OpenTelemetry::SDK::InstrumentationLibrary.new('OpenTelemetry::Instrumentation::Redis', 1)

    span_data = create_span_data(instrumentation_library: instrumentation_library)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]
    _(datadog_span_info.span_type).must_equal(::Datadog::Contrib::Redis::Ext::TYPE)
  end

  it 'sets a valid datadog error, message, and type' do
    err_type = 'NoMethodError'
    err_msg = 'No Method'
    err_stack = 'abcdef'
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }

    events = [
      OpenTelemetry::SDK::Trace::Event.new(
        name: 'error', attributes: { 'error.type' => err_type, 'error.msg' => err_msg, 'error.stack' => err_stack }
      )
    ]

    status = OpenTelemetry::Trace::Status.new(2, description: 'not found')

    span_data = create_span_data(attributes: attributes, events: events, status: status)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.status).must_equal(1)
    _(datadog_span_info.get_tag('error.type')).must_equal(err_type)
    _(datadog_span_info.get_tag('error.msg')).must_equal(err_msg)
    _(datadog_span_info.get_tag('error.stack')).must_equal(err_stack)
  end

  it 'sets the sampling rate to 0 for requests to the datadog-agent' do
    attributes = { 'http.method' => 'POST', 'http.route' => 'http://datadog-agent/v0.4/traces' }

    span_data = create_span_data(attributes: attributes)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.to_hash[:metrics]['_sample_rate']).must_equal(-1)
  end

  it 'sets the resource attributes as tags but not service.name, service.version, or deployment.environment' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }
    otel_resource_attributes = { 'service.name' => 'resource_defined_service',
                                 'service.version' => 'v1', 'other_info' => 'arbitrary_tag', 'deployment.environment' => 'prod' }
    otel_resource = create_resource(attributes: otel_resource_attributes)

    span_data = create_span_data(attributes: attributes, resource: otel_resource)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    assert_nil(datadog_span_info.get_tag('service.version'))
    assert_nil(datadog_span_info.get_tag('service.name'))
    assert_nil(datadog_span_info.get_tag('deployment.environment'))
    _(datadog_span_info.get_tag('other_info')).must_equal('arbitrary_tag')
  end

  it 'sets the resource attributes service.name as span service if it exists' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }
    otel_resource_attributes = { 'service.name' => 'resource_defined_service', 'service.version' => 'v1', 'other_info' => 'arbitrary_tag' }
    otel_resource = create_resource(attributes: otel_resource_attributes)

    span_data = create_span_data(attributes: attributes, resource: otel_resource)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.service).must_equal('resource_defined_service')
  end

  it 'defaults to user provided service name if the resource attributes service.name does not exist' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }
    otel_resource_attributes = { 'service.version' => 'v1', 'other_info' => 'arbitrary_tag' }
    otel_resource = create_resource(attributes: otel_resource_attributes)

    span_data = create_span_data(attributes: attributes, resource: otel_resource)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.service).must_equal('example_service')
  end

  it 'sets the resource attributes service.version as span version if it exists' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }
    otel_resource_attributes = { 'service.name' => 'resource_defined_service', 'service.version' => 'v1', 'other_info' => 'arbitrary_tag' }
    otel_resource = create_resource(attributes: otel_resource_attributes)

    span_data = create_span_data(attributes: attributes, resource: otel_resource)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service', 'example_env', 'fallback_version')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.get_tag('version')).must_equal('v1')
  end

  it 'defaults to user provided version name if the resource attributes service.version does not exist' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }
    otel_resource_attributes = { 'service.name' => 'resource_defined_service', 'other_info' => 'arbitrary_tag' }
    otel_resource = create_resource(attributes: otel_resource_attributes)

    span_data = create_span_data(attributes: attributes, resource: otel_resource)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service', 'example_env', 'fallback_version')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.get_tag('version')).must_equal('fallback_version')
  end

  it 'sets the resource attributes deployment.environment as span env if it exists' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }
    otel_resource_attributes = { 'service.name' => 'resource_defined_service',
                                 'service.version' => 'v1', 'other_info' => 'arbitrary_tag', 'deployment.environment' => 'prod' }
    otel_resource = create_resource(attributes: otel_resource_attributes)

    span_data = create_span_data(attributes: attributes, resource: otel_resource)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service', 'fallback_env')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.get_tag('env')).must_equal('prod')
  end

  it 'defaults to user provided env if the resource attributes deployment.environment does not exist' do
    attributes = { 'http.method' => 'GET', 'http.route' => '/example/api' }
    otel_resource_attributes = { 'service.version' => 'v1', 'other_info' => 'arbitrary_tag' }
    otel_resource = create_resource(attributes: otel_resource_attributes)

    span_data = create_span_data(attributes: attributes, resource: otel_resource)
    encoded_spans = span_encoder.translate_to_datadog([span_data], 'example_service', 'fallback_env')
    datadog_span_info = encoded_spans[0]

    _(datadog_span_info.get_tag('env')).must_equal('fallback_env')
  end

  def create_span_data(attributes: nil, events: nil, links: nil, trace_id: OpenTelemetry::Trace.generate_trace_id, trace_flags: OpenTelemetry::Trace::TraceFlags::DEFAULT, status: nil, instrumentation_library: nil, resource: nil)
    OpenTelemetry::SDK::Trace::SpanData.new(
      'example_name',
      nil,
      status,
      OpenTelemetry::Trace::INVALID_SPAN_ID,
      0,
      0,
      0,
      Time.now,
      Time.now,
      attributes,
      links,
      events,
      resource,
      instrumentation_library,
      OpenTelemetry::Trace.generate_span_id,
      trace_id,
      trace_flags
    )
  end

  def create_resource(attributes: {})
    OpenTelemetry::SDK::Resources::Resource.create(attributes)
  end
end
