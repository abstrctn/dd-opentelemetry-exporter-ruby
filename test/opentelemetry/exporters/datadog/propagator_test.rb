# frozen_string_literal: true

# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache 2.0 license (see LICENSE).
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2020 Datadog, Inc.

require 'test_helper'

# Give access to otherwise private members
module OpenTelemetry
  class Context
    module Propagation
      class CompositePropagator
        attr_accessor :injectors, :extractors
      end
    end
  end
end

describe OpenTelemetry::Exporters::Datadog::Exporter do
  Span = OpenTelemetry::Trace::Span
  SpanContext = OpenTelemetry::Trace::SpanContext

  let(:current_span_key) do
    OpenTelemetry::Trace::Propagation::ContextKeys.current_span_key
  end

  let(:propagator) do
    OpenTelemetry::Exporters::Datadog::Propagator.new
  end

  let(:otel_span_id) do
    ('1' * 16)
  end

  let(:otel_trace_id) do
    ('f' * 32)
  end

  let(:dd_span_id) do
    otel_span_id.to_i(16).to_s
  end

  let(:dd_trace_id) do
    otel_trace_id[16, 16].to_i(16).to_s
  end

  let(:dd_sampled) do
    '1'
  end

  let(:dd_not_sampled) do
    '0'
  end

  let(:valid_dd_headers) do
    {
      'x-datadog-trace-id' => dd_trace_id,
      'x-datadog-parent-id' => dd_span_id,
      'x-datadog-sampling-priority' => dd_sampled,
      'x-datadog-origin' => 'example_origin'
    }
  end

  let(:invalid_dd_headers) do
    {
      'x-datadog-traceinvalid-id' => ('i' * 17),
      'x-datadog-parentinvalid-id' => ('i' * 17),
      'x-datadog-sampling-priority' => dd_sampled,
      'x-datadog-origin' => 'example_origin'
    }
  end

  let(:rack_dd_headers) do
    {
      'HTTP_X_DATADOG_TRACE_ID' => dd_trace_id,
      'HTTP_X_DATADOG_PARENT_ID' => dd_span_id,
      'HTTP_X_DATADOG_SAMPLING_PRIORITY' => dd_sampled,
      'HTTP_X_DATADOG_ORIGIN' => 'example_origin'
    }
  end

  let(:trace_flags) do
    OpenTelemetry::Trace::TraceFlags.from_byte(1)
  end

  let(:tracestate_header) { '_dd_origin=example_origin' }
  let(:context) do
    span_context = SpanContext.new(trace_id: Array(otel_trace_id).pack('H*'), span_id: Array(otel_span_id).pack('H*'))
    span = Span.new(span_context: span_context)
    OpenTelemetry::Trace.context_with_span(span, parent_context: OpenTelemetry::Context.empty)
  end

  let(:context_with_tracestate) do
    span_context = SpanContext.new(trace_id: Array(otel_trace_id).pack('H*'), span_id: Array(otel_span_id).pack('H*'),
                                   tracestate: tracestate_header)
    span = Span.new(span_context: span_context)
    OpenTelemetry::Trace.context_with_span(span, parent_context: OpenTelemetry::Context.empty)
  end

  let(:context_with_trace_flags) do
    span_context = SpanContext.new(trace_id: Array(otel_trace_id).pack('H*'), span_id: Array(otel_span_id).pack('H*'), trace_flags: trace_flags)
    span = Span.new(span_context: span_context)
    OpenTelemetry::Trace.context_with_span(span, parent_context: OpenTelemetry::Context.empty)
  end

  let(:context_without_current_span) do
    span_context = SpanContext.new(trace_id: Array('f' * 32).pack('H*'), span_id: Array('1' * 16).pack('H*'),
                                   tracestate: tracestate_header)
    span = Span.new(span_context: span_context)
    OpenTelemetry::Trace.context_with_span(span, parent_context: OpenTelemetry::Context.empty)
  end

  describe '#inject' do
    it 'yields the carrier' do
    end

    it 'injects the datadog appropriate trace information into the carrier from the context, if provided' do
      carrier = propagator.inject({}, context) { |c, k, v| c[k] = v }
      _(carrier['x-datadog-trace-id']).must_equal(dd_trace_id.to_s)
      _(carrier['x-datadog-parent-id']).must_equal(dd_span_id)
      _(carrier['x-datadog-sampling-priority']).must_equal(dd_not_sampled)
    end

    it 'injects the datadog appropriate sampling priority into the carrier from the context, if provided' do
      carrier = propagator.inject({}, context_with_trace_flags) { |c, k, v| c[k] = v }
      _(carrier['x-datadog-trace-id']).must_equal(dd_trace_id)
      _(carrier['x-datadog-parent-id']).must_equal(dd_span_id)
      _(carrier['x-datadog-sampling-priority']).must_equal(dd_sampled)
    end

    it 'injects the datadog appropriate sampling priority into the carrier from the context, if provided' do
      carrier = propagator.inject({}, context_with_tracestate) { |c, k, v| c[k] = v }
      _(carrier['x-datadog-trace-id']).must_equal(dd_trace_id)
      _(carrier['x-datadog-parent-id']).must_equal(dd_span_id)
      _(carrier['x-datadog-origin']).must_equal('example_origin')
    end
  end

  describe '#extract' do
    it 'returns original context on error' do
      parent_context = OpenTelemetry::Context.empty
      context = propagator.extract(invalid_dd_headers, parent_context)
      _(context).must_equal(parent_context)
    end

    it 'returns a remote SpanContext with fields from the datadog headers' do
      context = propagator.extract(valid_dd_headers, OpenTelemetry::Context.empty)
      extracted_context = OpenTelemetry::Trace.current_span(context).context

      _(extracted_context.trace_id.unpack1('H*')).must_equal(otel_trace_id[0, 16])
      _(extracted_context.span_id.unpack1('H*')).must_equal(otel_span_id)
      _(extracted_context.trace_flags&.sampled?).must_equal(true)
      _(extracted_context.tracestate).must_equal(tracestate_header)
    end

    it 'accounts for rack specific headers' do
      context = propagator.extract(rack_dd_headers, OpenTelemetry::Context.empty)
      extracted_context = OpenTelemetry::Trace.current_span(context).context

      _(extracted_context.trace_id.unpack1('H*')).must_equal(otel_trace_id[0, 16])
      _(extracted_context.span_id.unpack1('H*')).must_equal(otel_span_id)
      _(extracted_context.trace_flags&.sampled?).must_equal(true)
      _(extracted_context.tracestate).must_equal(tracestate_header)
    end
  end

  describe '#auto_configure' do
    it 'includes datadog propagation in the http extractors and injectors' do
      default_http_propagators = OpenTelemetry.propagation

      OpenTelemetry::SDK.configure
      OpenTelemetry::Exporters::Datadog::Propagator.auto_configure

      # expect injects and extractors list to include datadog format
      updated_extractors = default_http_propagators.http.extractors
      updated_injectors = default_http_propagators.http.injectors

      _(updated_injectors.length).must_equal(3)
      _(updated_extractors.length).must_equal(3)
      _(updated_injectors.map(&:class)).must_include(OpenTelemetry::Exporters::Datadog::Propagator)
      _(updated_extractors.map(&:class)).must_include(OpenTelemetry::Exporters::Datadog::Propagator)
    end
  end
end
