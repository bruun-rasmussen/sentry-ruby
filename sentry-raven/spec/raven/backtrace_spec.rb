require 'spec_helper'

RSpec.describe Raven::Backtrace do
  before(:each) do
    @backtrace = Raven::Backtrace.parse(Thread.current.backtrace)
  end

  it "calls backtrace_cleanup_callback if it's present in the configuration" do
    called = false
    callback = proc do |backtrace|
      called = true
      backtrace
    end
    config = Raven.configuration
    config.backtrace_cleanup_callback = callback
    Raven::Backtrace.parse(Thread.current.backtrace, configuration: config)

    expect(called).to eq(true)
  end

  it "#lines" do
    expect(@backtrace.lines.first).to be_a(Raven::Backtrace::Line)
  end

  it "#inspect" do
    expect(@backtrace.inspect).to match(/Backtrace: .*>$/)
  end

  it "#to_s" do
    expect(@backtrace.to_s).to match(/backtrace_spec.rb:5/)
  end

  it "==" do
    @backtrace2 = Raven::Backtrace.new(@backtrace.lines)
    expect(@backtrace).to be == @backtrace2
  end

  it "parses every line of a real backtrace on the running Ruby" do
    # Regression guard: when the method-label format changed in Ruby 3.4, every
    # line silently failed to parse and was built with a nil file, which
    # Event#stacktrace_interface_from then dropped -- so events reached Sentry
    # with no stacktrace at all.
    lines = Raven::Backtrace.parse(caller).lines

    expect(lines).not_to be_empty
    expect(lines.map(&:file)).to all(be_a(String))
    expect(lines.map(&:number)).to all(be > 0)
  end

  describe Raven::Backtrace::Line do
    it "parses the Ruby >= 3.4 method label format" do
      line = described_class.parse("app/models/user.rb:42:in 'User#save'")

      expect(line.file).to eq("app/models/user.rb")
      expect(line.number).to eq(42)
      expect(line.method).to eq("User#save")
    end

    it "parses the Ruby <= 3.3 method label format" do
      line = described_class.parse("app/models/user.rb:42:in `save'")

      expect(line.file).to eq("app/models/user.rb")
      expect(line.number).to eq(42)
      expect(line.method).to eq("save")
    end

    it "parses a block label" do
      line = described_class.parse("app/models/user.rb:42:in 'block in User#save'")

      expect(line.method).to eq("block in User#save")
    end

    it "parses a line with no method label" do
      line = described_class.parse("app/models/user.rb:42")

      expect(line.file).to eq("app/models/user.rb")
      expect(line.number).to eq(42)
      expect(line.method).to be_nil
    end

    it "parses a Ruby internal frame" do
      line = described_class.parse("<internal:kernel>:187:in 'Kernel#loop'")

      expect(line.file).to eq("<internal:kernel>")
      expect(line.number).to eq(187)
      expect(line.method).to eq("Kernel#loop")
    end

    it "parses a JRuby frame" do
      line = described_class.parse("org.jruby.runtime.callsite.CachingCallSite.call(CachingCallSite.java:170)")

      expect(line.file).to eq("CachingCallSite.java")
      expect(line.number).to eq(170)
      expect(line.method).to eq("call")
      expect(line.module_name).to eq("org.jruby.runtime.callsite.CachingCallSite")
    end
  end
end
