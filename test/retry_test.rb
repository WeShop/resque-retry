require File.dirname(__FILE__) + '/test_helper'

class RetryTest < Test::Unit::TestCase
  def setup
    Resque.redis.flushall
    @worker = Resque::Worker.new(:testing)
    @worker.register_worker
  end

  def test_resque_plugin_lint
    assert_nothing_raised do
      Resque::Plugin.lint(Resque::Plugins::Retry)
    end
  end

  def test_default_settings
    assert_equal 1, RetryDefaultsJob.retry_limit, 'default retry limit'
    assert_equal 0, RetryDefaultsJob.retry_attempt, 'default number of retry attempts'
    assert_equal nil, RetryDefaultsJob.retry_exceptions, 'default retry exceptions; nil = any'
    assert_equal 0, RetryDefaultsJob.retry_delay, 'default seconds until retry'
  end

  def test_retry_once_by_default
    Resque.enqueue(RetryDefaultsJob)
    3.times do
      perform_next_job(@worker)
    end

    assert_equal 0, Resque.info[:pending], 'pending jobs'
    assert_equal 2, Resque.info[:failed], 'failed jobs'
    assert_equal 2, Resque.info[:processed], 'processed job'
  end

  def test_job_args_are_maintained
    test_args = ['maiow', 'cat', [42, 84]]

    Resque.enqueue(RetryDefaultsJob, *test_args)
    perform_next_job(@worker)

    assert job = Resque.pop(:testing)
    assert_equal test_args, job['args']
  end

  def test_job_args_may_be_modified
    Resque.enqueue(RetryWithModifiedArgsJob, 'foo', 'bar')
    perform_next_job(@worker)

    assert job = Resque.pop(:testing)
    assert_equal ['foobar', 'barbar'], job['args']
  end

  def test_retry_never_give_up
    Resque.enqueue(NeverGiveUpJob)
    10.times do
      perform_next_job(@worker)
    end

    assert_equal 1, Resque.info[:pending], 'pending jobs'
    assert_equal 10, Resque.info[:failed], 'failed jobs'
    assert_equal 10, Resque.info[:processed], 'processed job'
  end

  def test_fail_five_times_then_succeed
    Resque.enqueue(FailFiveTimesJob)
    7.times do
      perform_next_job(@worker)
    end

    assert_equal 5, Resque.info[:failed], 'failed jobs'
    assert_equal 6, Resque.info[:processed], 'processed job'
    assert_equal 0, Resque.info[:pending], 'pending jobs'
  end

  def test_can_determine_if_exception_may_be_retried
    assert_equal true, RetryDefaultsJob.retry_exception?(StandardError), 'StandardError may retry'
    assert_equal true, RetryDefaultsJob.retry_exception?(CustomException), 'CustomException may retry'
    assert_equal true, RetryDefaultsJob.retry_exception?(HierarchyCustomException), 'HierarchyCustomException may retry'

    assert_equal true, RetryCustomExceptionsJob.retry_exception?(CustomException), 'CustomException may retry'
    assert_equal true, RetryCustomExceptionsJob.retry_exception?(HierarchyCustomException), 'HierarchyCustomException may retry'
    assert_equal false, RetryCustomExceptionsJob.retry_exception?(AnotherCustomException), 'AnotherCustomException may not retry'
  end

  def test_retry_if_failed_and_exception_may_retry
    Resque.enqueue(RetryCustomExceptionsJob, CustomException)
    Resque.enqueue(RetryCustomExceptionsJob, HierarchyCustomException)
    4.times do
      perform_next_job(@worker)
    end

    assert_equal 4, Resque.info[:failed], 'failed jobs'
    assert_equal 4, Resque.info[:processed], 'processed job'
    assert_equal 2, Resque.info[:pending], 'pending jobs'
  end

  def test_do_not_retry_if_failed_and_exception_does_not_allow_retry
    Resque.enqueue(RetryCustomExceptionsJob, AnotherCustomException)
    Resque.enqueue(RetryCustomExceptionsJob, RuntimeError)
    4.times do
      perform_next_job(@worker)
    end

    assert_equal 2, Resque.info[:failed], 'failed jobs'
    assert_equal 2, Resque.info[:processed], 'processed job'
    assert_equal 0, Resque.info[:pending], 'pending jobs'
  end

  def test_delete_redis_key_when_job_is_successful
    Resque.enqueue(GoodJob, 'arg1')

    assert_equal nil, Resque.redis.get(GoodJob.redis_retry_key('arg1'))
    perform_next_job(@worker)
    assert_equal nil, Resque.redis.get(GoodJob.redis_retry_key('arg1'))
  end

  def test_delete_redis_key_after_final_failed_retry
    Resque.enqueue(FailFiveTimesJob, 'yarrrr')
    assert_equal nil, Resque.redis.get(FailFiveTimesJob.redis_retry_key('yarrrr'))

    perform_next_job(@worker)
    assert_equal '0', Resque.redis.get(FailFiveTimesJob.redis_retry_key('yarrrr'))

    perform_next_job(@worker)
    assert_equal '1', Resque.redis.get(FailFiveTimesJob.redis_retry_key('yarrrr'))

    5.times do
      perform_next_job(@worker)
    end
    assert_equal nil, Resque.redis.get(FailFiveTimesJob.redis_retry_key('yarrrr'))

    assert_equal 5, Resque.info[:failed], 'failed jobs'
    assert_equal 6, Resque.info[:processed], 'processed job'
    assert_equal 0, Resque.info[:pending], 'pending jobs'
  end

  def test_job_without_args_has_no_ending_colon_in_redis_key
    assert_equal 'resque-retry:GoodJob:yarrrr', GoodJob.redis_retry_key('yarrrr')
    assert_equal 'resque-retry:GoodJob:foo', GoodJob.redis_retry_key('foo')
    assert_equal 'resque-retry:GoodJob', GoodJob.redis_retry_key
  end

  def test_redis_retry_key_removes_whitespace
    assert_equal 'resque-retry:GoodJob:arg1-removespace', GoodJob.redis_retry_key('arg1', 'remove space')
  end
end