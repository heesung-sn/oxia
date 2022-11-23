package oxia

import (
	"github.com/pkg/errors"
	"go.uber.org/multierr"
	"time"
)

const (
	DefaultBatchLinger         = 5 * time.Millisecond
	DefaultMaxRequestsPerBatch = 1000
	DefaultBatchRequestTimeout = 30 * time.Second
)

var (
	ErrorBatchLinger         = errors.New("BatchLinger must be greater than or equal to zero")
	ErrorMaxRequestsPerBatch = errors.New("MaxRequestsPerBatch must be greater than zero")
	ErrorBatchRequestTimeout = errors.New("BatchRequestTimeout must be greater than zero")
)

// ClientOptions contains options for the Oxia client.
type ClientOptions struct {
	serviceUrl          string
	batchLinger         time.Duration
	maxRequestsPerBatch int
	batchRequestTimeout time.Duration
}

// ServiceUrl is the target host:port of any Oxia server to bootstrap the client. It is used for establishing the
// shard assignments. Ideally this should be a load-balanced endpoint.
func (o ClientOptions) ServiceUrl() string {
	return o.serviceUrl
}

// BatchLinger defines how long the batcher will wait before sending a batched request. The value must be greater
// than or equal to zero. A value of zero will disable linger, effectively disabling batching.
func (o ClientOptions) BatchLinger() time.Duration {
	return o.batchLinger
}

// MaxRequestsPerBatch defines how many individual requests a batch can contain before the batched request is sent.
// The value must be greater than zero. A value of one will effectively disable batching.
func (o ClientOptions) MaxRequestsPerBatch() int {
	return o.maxRequestsPerBatch
}

// BatchRequestTimeout defines how long the client will wait for responses before cancelling the request and failing
// the batch.
func (o ClientOptions) BatchRequestTimeout() time.Duration {
	return o.batchRequestTimeout
}

// ClientOption is an interface for applying Oxia client options.
type ClientOption interface {
	// apply is used to set a ClientOption value of a ClientOptions.
	apply(option ClientOptions) (ClientOptions, error)
}

func NewClientOptions(serviceUrl string, opts ...ClientOption) (ClientOptions, error) {
	options := ClientOptions{
		serviceUrl:          serviceUrl,
		batchLinger:         DefaultBatchLinger,
		maxRequestsPerBatch: DefaultMaxRequestsPerBatch,
		batchRequestTimeout: DefaultBatchRequestTimeout,
	}
	var errs error
	var err error
	for _, o := range opts {
		options, err = o.apply(options)
		if err != nil {
			errs = multierr.Append(errs, err)
		}
	}
	return options, errs
}

type clientOptionFunc func(ClientOptions) (ClientOptions, error)

func (f clientOptionFunc) apply(c ClientOptions) (ClientOptions, error) {
	return f(c)
}

func WithBatchLinger(batchLinger time.Duration) ClientOption {
	return clientOptionFunc(func(options ClientOptions) (ClientOptions, error) {
		if batchLinger < 0 {
			return options, ErrorBatchLinger
		}
		options.batchLinger = batchLinger
		return options, nil
	})
}

func WithMaxRequestsPerBatch(maxRequestsPerBatch int) ClientOption {
	return clientOptionFunc(func(options ClientOptions) (ClientOptions, error) {
		if maxRequestsPerBatch <= 0 {
			return options, ErrorMaxRequestsPerBatch
		}
		options.maxRequestsPerBatch = maxRequestsPerBatch
		return options, nil
	})
}

func WithBatchRequestTimeout(batchRequestTimeout time.Duration) ClientOption {
	return clientOptionFunc(func(options ClientOptions) (ClientOptions, error) {
		if batchRequestTimeout <= 0 {
			return options, ErrorBatchRequestTimeout
		}
		options.batchRequestTimeout = batchRequestTimeout
		return options, nil
	})
}